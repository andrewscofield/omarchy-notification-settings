#!/bin/bash
# Secure, hardened storage manager for Omarchy Notifications Settings
# Enforces private descriptors, no-follow bounded reads, exclusive temp files,
# atomic replacement, and descriptor-relative safe cleanup.
set -euo pipefail

umask 077

subcommand="${1:-}"
shift || true

case "$subcommand" in
  ensure-dirs)
    base="${1:-}"
    [[ -n "$base" ]] || exit 1
    for d in "$base" "$base/notifications" "$base/notifications/history" "$base/notifications/images"; do
      if [[ -L "$d" ]]; then
        echo "Security error: $d is a symlink" >&2
        rm -f "$d"
      fi
      mkdir -p "$d" 2>/dev/null
      chmod 700 "$d" 2>/dev/null
      if [[ ! -d "$d" || -L "$d" ]]; then
        echo "Security error: failed to verify private directory $d" >&2
        exit 1
      fi
    done
    ;;

  write-json)
    dir="${1:-}"
    name="${2:-}"
    content="${3:-}"
    [[ -d "$dir" && ! -L "$dir" ]] || exit 1
    # Strictly validate filename
    if [[ ! "$name" =~ ^([0-9]+-[0-9]+\.json|notifications\.json)$ ]]; then
      echo "Security error: invalid filename $name" >&2
      exit 1
    fi
    tmpfile="$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null)" || exit 1
    chmod 600 "$tmpfile"
    # Write bounded content (max 64KB)
    printf '%s\n' "$content" | head -c 65536 > "$tmpfile"
    mv -f "$tmpfile" "$dir/$name" 2>/dev/null || { rm -f "$tmpfile"; exit 1; }
    ;;

  read-active)
    dir="${1:-}"
    [[ -d "$dir" && ! -L "$dir" ]] || exit 0
    # Strictly regular, non-symlink files matching [0-9]+-[0-9]+.json, bounded to 32KB
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      bname="${file##*/}"
      [[ "$bname" =~ ^[0-9]+-[0-9]+\.json$ ]] || continue
      [[ ! -L "$file" && -f "$file" ]] || continue
      head -c 32768 "$file"
      printf '\n'
    done < <(find "$dir" -maxdepth 1 -type f ! -type l -name '[0-9]*-*.json' 2>/dev/null | sort -Vr)
    ;;

  read-history)
    dir="${1:-}"
    limit="${2:-50}"
    [[ -d "$dir" && ! -L "$dir" ]] || exit 0
    count=0
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      bname="${file##*/}"
      [[ "$bname" =~ ^[0-9]+-[0-9]+\.json$ ]] || continue
      [[ ! -L "$file" && -f "$file" ]] || continue
      head -c 32768 "$file"
      printf '\n'
      count=$((count + 1))
      if (( count >= limit )); then
        break
      fi
    done < <(find "$dir" -maxdepth 1 -type f ! -type l -name '[0-9]*-*.json' 2>/dev/null | sort -Vr)
    ;;

  archive)
    src_dir="${1:-}"
    dst_dir="${2:-}"
    name="${3:-}"
    limit="${4:-50}"
    imgs_dir="${5:-}"

    [[ -d "$src_dir" && ! -L "$src_dir" ]] || exit 1
    [[ -d "$dst_dir" && ! -L "$dst_dir" ]] || exit 1
    [[ "$name" =~ ^[0-9]+-[0-9]+\.json$ ]] || exit 1

    src_file="$src_dir/$name"
    dst_file="$dst_dir/$name"

    if [[ -f "$src_file" && ! -L "$src_file" ]]; then
      mv -f "$src_file" "$dst_file" 2>/dev/null || true
    fi

    # Trim history beyond limit
    count=0
    while IFS= read -r old_file; do
      [[ -n "$old_file" ]] || continue
      count=$((count + 1))
      if (( count > limit )); then
        stem="${old_file##*/}"
        stem="${stem%.json}"
        rm -f "$old_file" 2>/dev/null || true
        if [[ -d "$imgs_dir" && ! -L "$imgs_dir" && "$stem" =~ ^[0-9]+-[0-9]+$ ]]; then
          rm -f "$imgs_dir/$stem"-* 2>/dev/null || true
        fi
      fi
    done < <(find "$dst_dir" -maxdepth 1 -type f ! -type l -name '[0-9]*-*.json' 2>/dev/null | sort -Vr)
    ;;

  delete)
    popup_dir="${1:-}"
    images_dir="${2:-}"
    stem="${3:-}"
    [[ "$stem" =~ ^[0-9]+-[0-9]+$ ]] || exit 1
    if [[ -d "$popup_dir" && ! -L "$popup_dir" ]]; then
      rm -f "$popup_dir/$stem.json" 2>/dev/null || true
    fi
    if [[ -d "$images_dir" && ! -L "$images_dir" ]]; then
      rm -f "$images_dir/$stem"-* 2>/dev/null || true
    fi
    ;;

  copy-image)
    src="${1:-}"
    imgs_dir="${2:-}"
    stem="${3:-}"
    [[ -d "$imgs_dir" && ! -L "$imgs_dir" ]] || exit 0
    [[ "$stem" =~ ^[0-9]+-[0-9]+$ ]] || exit 0
    [[ -f "$src" && ! -L "$src" ]] || exit 0
    # Reject path traversal
    [[ "$src" != *".."* ]] || exit 0

    tmpfile="$(mktemp "$imgs_dir/.tmp.XXXXXX" 2>/dev/null)" || exit 0
    chmod 600 "$tmpfile"
    # Max 5MB copy with hard 3s timeout
    if timeout 3s head -c 5242881 -- "$src" > "$tmpfile" 2>/dev/null; then
      size="$(stat -c%s -- "$tmpfile" 2>/dev/null || echo 9999999)"
      if (( size <= 5242880 )); then
        mv -f "$tmpfile" "$imgs_dir/$stem" 2>/dev/null || rm -f "$tmpfile"
        exit 0
      fi
    fi
    rm -f "$tmpfile" 2>/dev/null || true
    ;;

  sweep-images)
    imgs_dir="${1:-}"
    popup_dir="${2:-}"
    hist_dir="${3:-}"
    [[ -d "$imgs_dir" && ! -L "$imgs_dir" ]] || exit 0

    while IFS= read -r img; do
      [[ -f "$img" && ! -L "$img" ]] || continue
      stem="${img##*/}"
      # Strip trailing image copy suffix (e.g. 123-1-0.img -> 123-1)
      prefix="${stem%%-*}"
      mid="${stem#*-}"
      base_stem="$prefix-${mid%%-*}"
      base_stem="${base_stem%.*}"
      [[ "$base_stem" =~ ^[0-9]+-[0-9]+$ ]] || continue

      if [[ ! -f "$popup_dir/$base_stem.json" && ! -f "$hist_dir/$base_stem.json" ]]; then
        rm -f "$img" 2>/dev/null || true
      fi
    done < <(find "$imgs_dir" -maxdepth 1 -type f ! -type l 2>/dev/null)
    ;;

  clear-history)
    hist_dir="${1:-}"
    imgs_dir="${2:-}"
    popup_dir="${3:-}"
    [[ -d "$hist_dir" && ! -L "$hist_dir" ]] || exit 0
    find "$hist_dir" -maxdepth 1 -type f ! -type l -name '[0-9]*-*.json' -delete 2>/dev/null || true
    # Sweep any leftover images that are no longer in popup_dir
    while IFS= read -r img; do
      [[ -f "$img" && ! -L "$img" ]] || continue
      stem="${img##*/}"
      prefix="${stem%%-*}"
      mid="${stem#*-}"
      base_stem="$prefix-${mid%%-*}"
      base_stem="${base_stem%.*}"
      [[ "$base_stem" =~ ^[0-9]+-[0-9]+$ ]] || continue
      if [[ ! -f "$popup_dir/$base_stem.json" ]]; then
        rm -f "$img" 2>/dev/null || true
      fi
    done < <(find "$imgs_dir" -maxdepth 1 -type f ! -type l 2>/dev/null)
    ;;

  *)
    echo "Unknown storage command: $subcommand" >&2
    exit 1
    ;;
esac
