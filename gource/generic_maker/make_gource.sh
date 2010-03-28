#!/usr/bin/bash

# This script generates a Gource video of a specific git directory
if [ ! $1 ]
then
  echo "Please supply a path + git dir! ( make_gource.sh /home/apoc/git_repos Moose )"
  exit
fi
cd $1

gource $2/ -1280x720 -s 0.001 --highlight-all-users --multi-sampling \
  --user-image-dir $2/gravatars/ --user-scale 1.5 \
  --disable-bloom --elasticity 0.0001 --max-file-lag 0.000001 --max-files 1000000 \
  --date-format "$2 Activity On %B %d, %Y" --disable-progress --stop-on-idle \
  --output-ppm-stream - | ffmpeg -y -b 5000K -r 40 -f image2pipe -vcodec ppm -i - -vcodec mpeg4 gource_$2.mp4
