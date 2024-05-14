set -ex

find . -type f -iname "*.wav" -exec sh -c \
    'f="{}"; noext=${f%.*}; ffmpeg -i "{}" -ar 48000 -c:a libopus -b:a 96K ${noext}.opus && rm {}' {} \;

find . -type f -iname "*.mp3" -exec sh -c \
    'f="{}"; noext=${f%.*}; ffmpeg -i "{}" -ar 48000 -c:a libopus -b:a 96K ${noext}.opus && rm {}' {} \;

find . -type f -iname "*.flac" -exec sh -c \
    'f="{}"; noext=${f%.*}; ffmpeg -i "{}" -ar 48000 -c:a libopus -b:a 96K ${noext}.opus && rm {}' {} \;

find . -type f -iname "*.ogg" -exec sh -c \
    'f="{}"; noext=${f%.*}; ffmpeg -i "{}" -ar 48000 -c:a libopus -b:a 96K ${noext}.opus && rm {}' {} \;

# Resample opus files to 48khz, as Mach requires. This is a little lossy, but that's okay.
find . -type f -iname "*.opus" -exec sh -c \
    'f="{}"; noext=${f%.*}; ffmpeg -i "{}" -ar 48000 -c:a libopus -b:a 96K ${noext}_new.opus && mv ${noext}_new.opus ${noext}.opus' {} \;

