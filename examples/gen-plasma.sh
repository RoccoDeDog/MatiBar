#!/bin/sh
# Regenerates the looping plasma video used by vbar.m (needs ffmpeg).
ffmpeg -y -f lavfi -i "nullsrc=s=800x120:d=3:r=30" -vf "format=rgb24,geq=\
r='128+127*sin(2*PI*(X/90 + T))':\
g='128+127*sin(2*PI*(Y/45 + 0.7*T + 0.3))':\
b='128+127*sin(2*PI*((X+Y)/120 + 1.3*T + 0.6))'" \
-pix_fmt yuv420p -an plasma.mp4
echo "Wrote examples/plasma.mp4 - point vbar.m at it to test video on the Touch Bar."
