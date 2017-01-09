#!/usr/bin/env bash

input=$1
output=$2
# target size in KB
THUMBNAIL_SIZE=${THUMBNAIL_SIZE:-300}

set -euo pipefail

if [ -z $input ] || [ -z $output ]; then
  # input is an HTTP-accessible GDAL-readable image
  # output is an S3 URI w/o extensions
  # e.g.:
  #   bin/process.sh \
  #   http://hotosm-oam.s3.amazonaws.com/uploads/2016-12-29/58655b07f91c99bd00e9c7ab/scene/0/scene-0-image-0-transparent_image_part2_mosaic_rgb.tif \
  #   s3://oam-dynamic-tiler-tmp/sources/58655b07f91c99bd00e9c7ab/0/58655b07f91c99bd00e9c7a6
  >&2 echo "usage: $(basename $0) <input> <output>"
  exit 1
fi

PATH=$(cd $(dirname "$0"); pwd -P):$PATH
source=$(mktemp)
intermediate=$(mktemp)

# 1. download source
>&2 echo "Downloading $input..."
if [[ $input =~ "s3://" ]]; then
  aws s3 cp $input $source
else
  curl -sfL $input -o $source
fi

# 2. transcode + generate overviews
>&2 echo "Transcoding..."
transcode.sh $source $intermediate
rm -f $source

# 3. upload TIF
>&2 echo "Uploading..."
aws s3 cp $intermediate ${output}.tif --acl public-read

if [ -f ${intermediate}.msk ]; then
  mask=1

  # 4. upload mask
  >&2 echo "Uploading mask..."
  aws s3 cp ${intermediate}.msk ${output}.tif.msk --acl public-read

  # 5. create RGBA VRT (for use in QGIS, etc.)
  >&2 echo "Generating RGBA VRT..."
  vrt=$(mktemp)
  http_output=${output/s3:\/\//http:\/\/s3.amazonaws.com\/}
  gdal_translate \
    -b 1 \
    -b 2 \
    -b 3 \
    -b mask \
    -of VRT \
    /vsicurl/${http_output}.tif $vrt

  perl -pe 's!(band="4"\>)!\1\n    <ColorInterp>Alpha</ColorInterp>!' $vrt | \
    perl -pe "s|/vsicurl/${http_output}|$(basename $output)|" | \
    perl -pe 's|(relativeToVRT=)"0"|$1"1"|' | \
    aws s3 cp - ${output}.vrt --acl public-read

  # 6. create footprint
  >&2 echo "Generating footprint..."
  rio shapes --mask --as-mask --sampling 100 --precision 6 $intermediate | \
    aws s3 cp - ${output}_footprint.json --acl public-read
else
  mask=0

  # 5. create RGB VRT (for parity)
  >&2 echo "Generating RGB VRT..."
  vrt=$(mktemp)
  http_output=${output/s3:\/\//http:\/\/s3.amazonaws.com\/}
  gdal_translate \
    -b 1 \
    -b 2 \
    -b 3 \
    -of VRT \
    /vsicurl/${http_output}.tif $vrt

  cat $vrt | \
    perl -pe "s|/vsicurl/${http_output}|$(basename $output)|" | \
    perl -pe 's|(relativeToVRT=)"0"|$1"1"|' | \
    aws s3 cp - ${output}.vrt --acl public-read

  # 6. create footprint (bounds of image)
  >&2 echo "Generating footprint..."
  rio bounds $intermediate | \
    aws s3 cp - ${output}_footprint.json --acl public-read
fi

rm -f $intermediate ${intermediate}.msk*

# 7. create thumbnail
>&2 echo "Generating thumbnail..."
thumb=$(mktemp)
height=$(rio info $vrt 2> /dev/null | jq .height)
width=$(rio info $vrt 2> /dev/null | jq .width)
target_pixel_area=$(bc -l <<< "$THUMBNAIL_SIZE * 1000 / 0.75")
ratio=$(bc -l <<< "sqrt($target_pixel_area / ($width * $height))")
target_width=$(printf "%.0f" $(bc -l <<< "$width * $ratio"))
target_height=$(printf "%.0f" $(bc -l <<< "$height * $ratio"))
gdal_translate -of png $vrt $thumb -outsize $target_width $target_height
aws s3 cp $thumb ${output}_thumb.png --acl public-read
rm -f $vrt $thumb

if [ "$mask" -eq 1 ]; then
  # 8. create and upload warped VRT
  >&2 echo "Generating warped VRT..."
  warped_vrt=$(mktemp)
  make_vrt.sh -r lanczos ${output}.tif > $warped_vrt
  aws s3 cp $warped_vrt ${output}_warped.vrt --acl public-read

  # 9. create and upload warped VRT for mask
  >&2 echo "Generating warped VRT for mask..."
  make_mask_vrt.py $warped_vrt | aws s3 cp - ${output}_warped_mask.vrt --acl public-read
else
  # 8. create and upload warped VRT
  >&2 echo "Generating warped VRT..."
  warped_vrt=$(mktemp)
  make_vrt.sh -r lanczos -a ${output}.tif > $warped_vrt
  aws s3 cp $warped_vrt ${output}_warped.vrt --acl public-read
fi

rm -f $warped_vrt

# 10. create and upload metadata
>&2 echo "Generating metadata..."
if [ "$mask" -eq 1 ]; then
  get_metadata.py --include-mask $output | aws s3 cp - ${output}.json --acl public-read
else
  get_metadata.py $output | aws s3 cp - ${output}.json --acl public-read
fi