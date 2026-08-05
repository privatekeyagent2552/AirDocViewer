from PIL import Image
import numpy as np

src = Image.open(r"C:\Users\hashi\AndroidStudioProjects\Fadocx\assets\fadocx_source.png")
px = np.array(src.convert("RGB"))
h, w = px.shape[:2]

for pt in [(10,10),(50,50),(100,100),(255,100),(255,200),(255,350),(100,350),(255,380),(255,400)]:
    x,y = pt
    if y<h and x<w:
        print(pt, px[y,x])

# Detect non-white, non-cream emblem on green - use saturation
r,g,b = px[:,:,0], px[:,:,1], px[:,:,2]
# Dark/mid green background inside icon
green_icon = (g > 60) & (g > r) & (g > b) & (r < 120)
ys, xs = np.where(green_icon)
print('green icon pixels', len(xs))
if len(xs):
    print('bbox', xs.min(), ys.min(), xs.max(), ys.max())

# Find where bottom white text bar starts
for y in range(h-1, int(h*0.4), -1):
    row = px[y]
    white = np.mean((row[:,0]>210)&(row[:,1]>210)&(row[:,2]>210))
    green = np.mean(green_icon[y])
    print(f'y={y} white={white:.2f} green={green:.2f}')
