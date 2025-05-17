#!/usr/bin/env bash
#
# Incus Backup & Restore Tool
# - full tarball of /var/lib/incus + /etc/subuid & /etc/subgid
# - ZFS snapshot & cleanup
# - safe restore via untar

set -euo pipefail
IFS=$'\n\t'

# 1. Select a ZFS pool
select_zfs_pool() {
  echo "Detecting available ZFS pools…"
  mapfile -t POOLS < <(sudo zpool list -H -o name)

  if [ "${#POOLS[@]}" -eq 0 ]; then
    echo "❌ No ZFS pools found. Please create one first." >&2
    exit 1
  elif [ "${#POOLS[@]}" -eq 1 ]; then
    ZFS_POOL="${POOLS[0]}"
    echo "→ Using only pool: ${ZFS_POOL}"
  else
    echo "Available ZFS pools:"
    for i in "${!POOLS[@]}"; do
      printf "  %d) %s\n" "$((i+1))" "${POOLS[i]}"
    done
    while true; do
      read -rp "Select pool [1-${#POOLS[@]}]: " idx
      if [[ "$idx" =~ ^[1-9][0-9]*$ ]] && [ "$idx" -le "${#POOLS[@]}" ]; then
        ZFS_POOL="${POOLS[idx-1]}"
        break
      fi
      echo "Invalid choice."
    done
    echo "→ Using pool: ${ZFS_POOL}"
  fi
}

# 2a. For Backup: select or create dataset
select_dataset_for_backup() {
  echo "Datasets in pool ${ZFS_POOL}:"
  mapfile -t DS < <(sudo zfs list -H -o name | grep "^${ZFS_POOL}/" || true)
  if [ "${#DS[@]}" -gt 0 ]; then
    for i in "${!DS[@]}"; do
      NAME=${DS[i]#${ZFS_POOL}/}
      printf "  %d) %s\n" "$((i+1))" "$NAME"
    done
    printf "  %d) Create new dataset\n" "$(( ${#DS[@]} + 1 ))"
  fi

  while true; do
    read -rp "Select dataset or create new [1-$(( ${#DS[@]} + 1 ))]: " idx
    if [[ "$idx" =~ ^[1-9][0-9]*$ ]] && [ "$idx" -le "$(( ${#DS[@]} + 1 ))" ]; then
      if [ "$idx" -le "${#DS[@]}" ]; then
        ZFS_DATASET=${DS[$((idx-1))]#${ZFS_POOL}/}
      else
        read -rp "Enter new dataset name [incus-backup]: " ZFS_DATASET
        ZFS_DATASET=${ZFS_DATASET:-incus-backup}
      fi
      break
    fi
    echo "Invalid choice."
  done
  echo "→ Using dataset: ${ZFS_POOL}/${ZFS_DATASET}"
}

# 2b. For Restore: select existing dataset
select_dataset_for_restore() {
  echo "Available datasets in pool ${ZFS_POOL}:"
  mapfile -t DS < <(sudo zfs list -H -o name | grep "^${ZFS_POOL}/" || true)
  if [ "${#DS[@]}" -eq 0 ]; then
    echo "❌ No datasets found in ${ZFS_POOL}." >&2
    exit 1
  fi
  for i in "${!DS[@]}"; do
    NAME=${DS[i]#${ZFS_POOL}/}
    printf "  %d) %s\n" "$((i+1))" "$NAME"
  done

  while true; do
    read -rp "Select dataset containing backups [1-${#DS[@]}]: " idx
    if [[ "$idx" =~ ^[1-9][0-9]*$ ]] && [ "$idx" -le "${#DS[@]}" ]; then
      ZFS_DATASET=${DS[$((idx-1))]#${ZFS_POOL}/}
      break
    fi
    echo "Invalid choice."
  done
  echo "→ Using dataset: ${ZFS_POOL}/${ZFS_DATASET}"
}

# 3. Ensure it's mounted (or let user set/change mountpoint)
setup_dataset() {
  FULL="${ZFS_POOL}/${ZFS_DATASET}"
  MP=$(sudo zfs get -H -o value mountpoint "${FULL}")

  if [[ "$MP" = "legacy" || "$MP" = "none" ]]; then
    default_mp="/mnt/${ZFS_POOL}-${ZFS_DATASET}"
    read -rp "No mountpoint set. Enter mountpoint [${default_mp}]: " choice_mp
    MP=${choice_mp:-$default_mp}
    [[ "$MP" != /* ]] && MP="/mnt/${MP}"
    echo "→ Setting mountpoint to ${MP}"
    sudo zfs set mountpoint="${MP}" "${FULL}"
  elif mountpoint -q "$MP"; then
    echo "→ Already mounted at ${MP}"
    read -rp "Keep this mountpoint? [Y/n]: " keep
    keep=${keep:-Y}
    if [[ "${keep^^}" =~ ^N ]]; then
      read -rp "Enter new mountpoint (absolute path): " newmp
      [[ "$newmp" != /* ]] && newmp="/mnt/${newmp}"
      echo "→ Resetting mountpoint to ${newmp}"
      sudo zfs set mountpoint="${newmp}" "${FULL}"
      MP="$newmp"
    fi
  else
    echo "→ Mounting dataset at ${MP}"
    sudo zfs mount "${FULL}"
  fi

  MOUNT_POINT="$MP"
  echo "→ Final mountpoint: ${MOUNT_POINT}"
}

# 4. Backup function
backup_incus() {
  local ts backup_dir tarfile
  ts=$(date +%Y%m%d-%H%M%S)
  backup_dir="${MOUNT_POINT}/incus-backups/${ts}"
  tarfile="incus-full-${ts}.tar.gz"

  echo "→ Stopping Incus services for a consistent backup"
  sudo systemctl stop incus.socket incus.service

  echo "→ Creating backup directory: ${backup_dir}"
  sudo mkdir -p "${backup_dir}"

  echo "→ Creating single tarball (data + UID/GID maps)"
  sudo tar czpf "${backup_dir}/${tarfile}" \
    -C / var/lib/incus \
    -C / etc/subuid etc/subgid

  echo "→ Creating ZFS snapshot ${ZFS_POOL}/${ZFS_DATASET}@incus-backup-${ts}"
  sudo zfs snapshot "${ZFS_POOL}/${ZFS_DATASET}@incus-backup-${ts}"

  echo "→ Cleaning old raw backups (>7d)"
  sudo find "${MOUNT_POINT}/incus-backups" -maxdepth 1 -type d \
       -name "[0-9]*" -mtime +7 -exec rm -rf {} +

  echo "→ Cleaning old snapshots (>7d)"
  sudo zfs list -H -t snapshot -o name "${ZFS_POOL}/${ZFS_DATASET}" \
    | grep 'incus-backup-' \
    | while read -r SNAP; do
        SNAP_DATE=${SNAP#*@incus-backup-}
        TS_SNAP=$(date -d "${SNAP_DATE}" +%s 2>/dev/null) || continue
        if [ "$TS_SNAP" -lt "$(date -d '7 days ago' +%s)" ]; then
          echo "  destroying ${SNAP}"
          sudo zfs destroy "${SNAP}"
        fi
      done

  echo "→ Restarting Incus services"
  sudo systemctl start incus.socket incus.service

  echo "✅ Backup complete: ${backup_dir}/${tarfile}"
}

# 5. Restore function
restore_incus() {
  mapfile -t BACKUPS < <(find "${MOUNT_POINT}/incus-backups" -maxdepth 1 -type d \
                         -name "[0-9]*" | sort)

  if [ "${#BACKUPS[@]}" -eq 0 ]; then
    echo "❌ No backups found under ${MOUNT_POINT}/incus-backups" >&2
    exit 1
  fi

  echo "Available backups:"
  for i in "${!BACKUPS[@]}"; do
    printf "  %d) %s\n" "$((i+1))" "$(basename "${BACKUPS[i]}")"
  done

  while true; do
    read -rp "Choose backup (# or 'latest'): " choice
    if [[ "$choice" == "latest" ]]; then
      sel="${BACKUPS[-1]}"; break
    elif [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#BACKUPS[@]}" ]; then
      sel="${BACKUPS[choice-1]}"; break
    fi
    echo "Invalid choice."
  done
  echo "→ Restoring: $(basename "$sel")"

  read -rp "This will stop Incus and overwrite data. Continue? (y/N) " yn
  case "${yn,,}" in y) ;; *) echo "Aborted."; exit 0 ;; esac

  echo "→ Stopping Incus services"
  sudo systemctl stop incus.socket incus.service

  echo "→ Untarring backup archive → /"
  sudo tar xzf "${sel}/incus-full-"*".tar.gz" -C /

  echo "→ Starting Incus services"
  sudo systemctl start incus.socket incus.service

  echo "✅ Restore complete. Verify with 'incus list' and 'systemctl status incus.service'"
}

# 6. Main menu
main_menu() {
  while :; do
    cat <<-EOF

    Incus Backup & Restore
    ======================
    1) Backup Incus
    2) Restore Incus
    3) Exit
EOF
    read -rp "Choice [1-3]: " opt
    case "$opt" in
      1)
        select_zfs_pool
        select_dataset_for_backup
        setup_dataset
        backup_incus
        ;;
      2)
        select_zfs_pool
        select_dataset_for_restore
        setup_dataset
        restore_incus
        ;;
      3) echo "Goodbye!"; exit 0 ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

main_menu
