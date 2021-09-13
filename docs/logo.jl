using Luxor

scale = 2
ratio = (√5 -1)/2

w, h = scale * 128 * 2, scale * 128 * 2

r1 = w/2
r2 = r1 * ratio
r3 = r2 * ratio
r4 = r3 * ratio

c1 = Point(0, 0)
c2 = c1 + Point(r1-r2, r1-r2) * √2/2
c3 = c1 + Point(r1-r3, r1-r3) * √2/2
c4 = c1 + Point(r1-r4, r1-r4) * √2/2

Drawing(w, h, "logo.svg")
background(1, 1, 1, 0)
Luxor.origin()

setcolor(1,1,1)
circle(c1, r1, :fill)
setcolor(0.251, 0.388, 0.847)  # dark blue
circle(c1, r1-4*scale, :fill)

setcolor(1,1,1)
circle(c2, r2, :fill)
setcolor(0.796, 0.235, 0.2)  # dark red
circle(c2, r2-4*scale, :fill)

setcolor(1,1,1)
circle(c3, r3, :fill)
setcolor(0.22, 0.596, 0.149) # dark green
circle(c3, r3-4*scale, :fill)

setcolor(1,1,1)
circle(c4, r4, :fill)
setcolor(0.584, 0.345, 0.698) # dark purple
circle(c4, r4-4*scale, :fill)

finish()