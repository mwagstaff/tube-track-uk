#!/bin/zsh

set -euo pipefail

if [[ "$#" -ne 3 ]]; then
    print -u2 "usage: copy_background_images.zsh <source-directory> <bundle-directory> <cache-directory>"
    exit 64
fi

readonly source_directory="$1"
readonly bundle_directory="$2"
readonly cache_directory="$3"
readonly maximum_pixel_dimension=2560
readonly jpeg_quality=78

if [[ ! -d "$source_directory" ]]; then
    print -u2 "error: background image directory does not exist: $source_directory"
    exit 1
fi

if [[ "${bundle_directory:t}" != "BackgroundImages" ]]; then
    print -u2 "error: refusing to replace unexpected bundle directory: $bundle_directory"
    exit 1
fi

typeset -a image_paths
while IFS= read -r -d '' image_path; do
    image_paths+=("$image_path")
done < <(
    /usr/bin/find "$source_directory" -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
           -o -iname '*.heic' -o -iname '*.heif' -o -iname '*.webp' \) \
        -print0 | /usr/bin/sort -z
)

if (( ${#image_paths[@]} == 0 )); then
    print -u2 "error: no supported background images found under $source_directory"
    exit 1
fi

/bin/rm -rf "$bundle_directory"
/bin/mkdir -p "$bundle_directory"
/bin/mkdir -p "$cache_directory"

readonly manifest_path="$bundle_directory/manifest.txt"
typeset -A optimized_relative_paths
for image_path in "${image_paths[@]}"; do
    relative_path="${image_path#"$source_directory"/}"
    optimized_relative_path="${relative_path:r}.jpg"
    if [[ -n "${optimized_relative_paths[$optimized_relative_path]-}" ]]; then
        print -u2 "error: multiple background images optimize to $optimized_relative_path"
        exit 1
    fi
    optimized_relative_paths[$optimized_relative_path]=1

    cached_path="$cache_directory/$optimized_relative_path"
    destination_path="$bundle_directory/$optimized_relative_path"
    synchronized_resource_path="${bundle_directory:h}/${image_path:t}"
    if [[ -f "$synchronized_resource_path" ]]; then
        if ! /usr/bin/cmp -s "$image_path" "$synchronized_resource_path"; then
            print -u2 "error: conflicting bundled resource named ${image_path:t}"
            exit 1
        fi
        /bin/rm "$synchronized_resource_path"
    fi
    /bin/mkdir -p "${cached_path:h}"
    /bin/mkdir -p "${destination_path:h}"
    if [[ ! -f "$cached_path" || "$image_path" -nt "$cached_path" ]]; then
        /usr/bin/sips \
            -s format jpeg \
            -s formatOptions "$jpeg_quality" \
            --resampleHeightWidthMax "$maximum_pixel_dimension" \
            "$image_path" \
            --out "$cached_path" >/dev/null
    fi
    /bin/cp -p "$cached_path" "$destination_path"
    /usr/bin/printf '%s\n' "$optimized_relative_path" >> "$manifest_path"
done

print "Bundled ${#image_paths[@]} optimized background image(s) (max ${maximum_pixel_dimension}px, JPEG quality ${jpeg_quality})."
