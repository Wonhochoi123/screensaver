#!/bin/bash
set -u

LAT="$1"; LON="$2"; Z="$3"; OUT_MAP="$4"; OUT_QR="$5"; OUTDIR="$6"
HUD_W="${7:-552}"; HUD_H="${8:-616}"; MAP_RING_COLOR="${9:-#FFFFFF}"

UA="Screensaver-App/1.0"
# OUTDIR is the screen-height-specific folder (…/Maps/h_<height>) that holds the
# composited HUD images. Raw map tiles look identical at every screen size, so
# they are cached once in a shared sibling folder (…/Maps/tiles) and reused
# across every resolution instead of being re-downloaded per height.
CACHE="$(dirname "$OUTDIR")/tiles"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUTDIR" "$CACHE"

if [ -s "$OUT_MAP" ] && [ -s "$OUT_QR" ]; then exit 0; fi

need_map=1; [ -s "$OUT_MAP" ] && need_map=0
need_qr=1;  [ -s "$OUT_QR"  ] && need_qr=0

if command -v magick >/dev/null 2>&1; then IM="magick"; else IM="convert"; fi
MAP_STYLE="satellite"

D=500
MARKER_COLOR='#ff5a4d'
RING=5
PAD=26
CANVAS=$(( D + PAD*2 ))
FULLH=$CANVAS
CX=$(( CANVAS/2 ))
MY=$(( PAD + D/2 ))
R=$(( D/2 ))

if [ "$need_qr" = 1 ]; then
    G_MAPS_URL="https://maps.google.com/?q=${LAT},${LON}"

    STYLED=0
    if python3 - "$G_MAPS_URL" "$TMP/qr_styled.png" "$D" <<'PY' 2>/dev/null
import sys, random
try:
    import qrcode
    from qrcode.image.styledpil import StyledPilImage
    try:
        from qrcode.image.styles.moduledrawers.pil import CircleModuleDrawer
    except Exception:
        from qrcode.image.styles.moduledrawers import CircleModuleDrawer
    from qrcode.image.styles.colormasks import SolidFillColorMask
    from PIL import Image, ImageDraw
except Exception:
    sys.exit(2)

url, out_png, D = sys.argv[1], sys.argv[2], int(sys.argv[3])
qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_H, border=0)
qr.add_data(url); qr.make(fit=True)
n = qr.modules_count

mask = SolidFillColorMask(back_color=(255, 255, 255, 0), front_color=(0, 0, 0, 255))
qr_img = qr.make_image(image_factory=StyledPilImage,
                       module_drawer=CircleModuleDrawer(),
                       color_mask=mask).convert("RGBA")

canvas = Image.new("RGBA", (D, D), (0, 0, 0, 0))
draw = ImageDraw.Draw(canvas)
draw.ellipse([0, 0, D - 1, D - 1], fill=(255, 255, 255, 255))    

pattern = Image.new("RGBA", (D, D), (0, 0, 0, 0))
pdraw = ImageDraw.Draw(pattern)

cell = int((D * 0.68) / float(n))
func = cell * n

qr_img = qr_img.resize((func, func), Image.LANCZOS)
cx = cy = D / 2.0
R = D / 2.0
half = func / 2.0

random.seed(len(url) * 7 + 13)

first_mod_x = cx - half + (cell / 2.0)
first_mod_y = cy - half + (cell / 2.0)
start_x = first_mod_x - (int(first_mod_x / cell) * cell)
start_y = first_mod_y - (int(first_mod_y / cell) * cell)

yy = start_y
while yy < D:
    xx = start_x
    while xx < D:
        if (xx - cx) ** 2 + (yy - cy) ** 2 <= (R - cell * 1.3) ** 2:
            if xx < (cx - half) or xx > (cx + half) or yy < (cy - half) or yy > (cy + half):
                if random.random() < 0.5:
                    r = cell * 0.40
                    pdraw.ellipse([xx - r, yy - r, xx + r, yy + r], fill=(0, 0, 0, 255))
        xx += cell
    yy += cell

pattern.alpha_composite(qr_img, (int(cx - half), int(cy - half)))

gradient = Image.new("RGBA", (D, D), (0, 0, 0, 0))
gdraw = ImageDraw.Draw(gradient)

center_color = (130, 40, 180)
edge_color = (30, 0, 60)

for rad in range(int(R), 0, -1):
    ratio = rad / R
    ease = ratio ** 1.5 
    r_col = int(center_color[0] + (edge_color[0] - center_color[0]) * ease)
    g_col = int(center_color[1] + (edge_color[1] - center_color[1]) * ease)
    b_col = int(center_color[2] + (edge_color[2] - center_color[2]) * ease)
    gdraw.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=(r_col, g_col, b_col, 255))

gradient.putalpha(pattern.getchannel("A"))

canvas.alpha_composite(gradient)
canvas.save(out_png)
PY
    then STYLED=1; fi

    if [ "$STYLED" != 1 ]; then
        qrencode -s 12 -m 2 -o "$TMP/qr_raw.png" "$G_MAPS_URL" || exit 6
        QR_FIT=330
        $IM "$TMP/qr_raw.png" -transparent white -resize ${QR_FIT}x${QR_FIT} "$TMP/qr_scaled.png"
        $IM -size ${D}x${D} xc:none -fill '#ffffffF2' -draw "circle $R,$R $R,1" "$TMP/qr_disc.png"
        QR_OFF=$(( (D - QR_FIT) / 2 ))
        $IM "$TMP/qr_disc.png" "$TMP/qr_scaled.png" -gravity northwest -geometry +${QR_OFF}+${QR_OFF} \
            -compose over -composite "$TMP/qr_styled.png"
    fi

    $IM -size ${CANVAS}x${FULLH} xc:none -fill black \
        -draw "circle ${CX},$((MY+4)) ${CX},$((MY+4-R))" \
        -blur 0x9 -channel A -evaluate multiply 0.5 +channel "$TMP/QR_shadow.png"
    $IM -size ${CANVAS}x${FULLH} xc:none \
        "$TMP/qr_styled.png" -gravity northwest -geometry +${PAD}+${PAD} -compose over -composite "$TMP/QR_disc.png"
    $IM -size ${CANVAS}x${FULLH} xc:none -stroke "#FFFFFF" -strokewidth ${RING} -fill none \
        -draw "circle ${CX},${MY} ${CX},$((MY-R))" "$TMP/QR_ring.png"
    $IM "$TMP/QR_ring.png" \( +clone -blur 0x4 -channel A -evaluate multiply 1.2 +channel \) \
        -compose over -composite "$TMP/QR_ringglow.png"

    $IM -size ${CANVAS}x${FULLH} xc:none -colorspace sRGB \
        "$TMP/QR_shadow.png" -composite "$TMP/QR_disc.png" -composite \
        "$TMP/QR_ringglow.png" -composite "$TMP/QR_final.png" || exit 5

    $IM "$TMP/QR_final.png" -resize ${HUD_W}x${HUD_H}\! -depth 8 bgra:"$OUT_QR" || exit 7
fi

if [ "$need_map" = 1 ]; then
    read XT YT PX PY < <(python3 - "$LAT" "$LON" "$Z" <<'PY'
import math, sys
lat, lon, z = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
n = 2.0 ** z
xf = (lon + 180.0) / 360.0 * n
lr = math.radians(lat)
yf = (1.0 - math.log(math.tan(lr) + 1.0/math.cos(lr)) / math.pi) / 2.0 * n
xt, yt = math.floor(xf), math.floor(yf)
print(xt, yt, round((xf-(xt-1))*256), round((yf-(yt-1))*256))
PY
) || exit 1

    SUBS=(a b c)
    for dy in -1 0 1; do for dx in -1 0 1; do
        tx=$((XT+dx)); ty=$((YT+dy))
        if [ "$MAP_STYLE" = "satellite" ]; then
            tf="$CACHE/sat_${Z}_${tx}_${ty}.png"
            tf_lab="$CACHE/lab_${Z}_${tx}_${ty}.png"
            url="https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/${Z}/${ty}/${tx}"
            url_lab="https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/${Z}/${ty}/${tx}"
        else
            tf="$CACHE/${Z}_${tx}_${ty}.png"
            sub=${SUBS[$(( (tx+ty) % 3 ))]}
            url="https://${sub}.tile.openstreetmap.org/${Z}/${tx}/${ty}.png"
        fi
        
        if [ ! -s "$tf" ]; then
            curl -sf --max-time 8 --create-dirs -A "$UA" -o "$tf" "$url" &
        fi
        if [ "$MAP_STYLE" = "satellite" ] && [ ! -s "$tf_lab" ]; then
            curl -sf --max-time 8 --create-dirs -A "$UA" -o "$tf_lab" "$url_lab" &
        fi
    done; done
    wait 

    for dy in -1 0 1; do for dx in -1 0 1; do
        tx=$((XT+dx)); ty=$((YT+dy))
        if [ "$MAP_STYLE" = "satellite" ]; then
            tf="$CACHE/sat_${Z}_${tx}_${ty}.png"
            tf_lab="$CACHE/lab_${Z}_${tx}_${ty}.png"
            if [ -s "$tf_lab" ]; then
                $IM "$tf" "$tf_lab" -compose over -composite "$TMP/t_${dx}_${dy}.png"
            else
                cp "$tf" "$TMP/t_${dx}_${dy}.png"
            fi
        else
            tf="$CACHE/${Z}_${tx}_${ty}.png"
            cp "$tf" "$TMP/t_${dx}_${dy}.png"
        fi
    done; done

    $IM \
      \( "$TMP/t_-1_-1.png" "$TMP/t_0_-1.png" "$TMP/t_1_-1.png" +append \) \
      \( "$TMP/t_-1_0.png"  "$TMP/t_0_0.png"  "$TMP/t_1_0.png"  +append \) \
      \( "$TMP/t_-1_1.png"  "$TMP/t_0_1.png"  "$TMP/t_1_1.png"  +append \) \
      -append "$TMP/stitch.png" || exit 3

    OFFX=$(( PX - D/2 )); OFFY=$(( PY - D/2 ))
    $IM "$TMP/stitch.png" -crop ${D}x${D}+${OFFX}+${OFFY} +repage \
        -background none -gravity center -extent ${D}x${D} "$TMP/crop.png" || exit 4

    $IM -size ${D}x${D} xc:none -fill white -draw "circle $R,$R $R,1" "$TMP/mask.png"
    $IM "$TMP/crop.png" "$TMP/mask.png" -alpha off -compose CopyOpacity -composite "$TMP/disc.png"
    $IM -size ${CANVAS}x${FULLH} xc:none -fill black \
        -draw "circle ${CX},$((MY+4)) ${CX},$((MY+4-R))" \
        -blur 0x9 -channel A -evaluate multiply 0.5 +channel "$TMP/M_shadow.png"
    $IM -size ${CANVAS}x${FULLH} xc:none \
        "$TMP/disc.png" -gravity northwest -geometry +${PAD}+${PAD} -compose over -composite "$TMP/M_disc.png"
    $IM -size ${CANVAS}x${FULLH} xc:none -stroke "$MAP_RING_COLOR" -strokewidth ${RING} -fill none \
        -draw "circle ${CX},${MY} ${CX},$((MY-R))" "$TMP/M_ring.png"
    $IM "$TMP/M_ring.png" \( +clone -blur 0x4 -channel A -evaluate multiply 1.2 +channel \) \
        -compose over -composite "$TMP/M_ringglow.png"
    $IM -size ${CANVAS}x${FULLH} xc:none \
        -fill "$MARKER_COLOR" -draw "circle ${CX},${MY} ${CX},$((MY-7))" \
        -fill white          -draw "circle ${CX},${MY} ${CX},$((MY-3))" "$TMP/M_marker.png"

    $IM -size ${CANVAS}x${FULLH} xc:none -colorspace sRGB \
        "$TMP/M_shadow.png" -composite "$TMP/M_disc.png" -composite \
        "$TMP/M_ringglow.png" -composite "$TMP/M_marker.png" -composite "$TMP/M_final.png" || exit 5
    
    $IM "$TMP/M_final.png" -resize ${HUD_W}x${HUD_H}\! -depth 8 bgra:"$OUT_MAP" || exit 7
fi

exit 0
