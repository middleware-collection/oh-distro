import numpy as np

blockName = 'cinderblock'
blockSize = np.array([15 + 5/8.0, 15 + 3/8.0, 5 + 5/8.0]) * 0.0254 # meters
blockTiltAngle = 15 # degrees


# F=sloping up forward (+x), B=sloping up backward (-x),
# R=sloping up rightward (-y), L=sloping up leftward (+y)
# last row is closest to robot (robot is on bottom looking up)
# column order is left-to-right on robot (+y to -y)
blockTypes = [
    [ 'B', 'L', 'F', 'R', 'B', 'L' ],
    [ 'L', 'F', 'R', 'B', 'L', 'F' ],
    [ 'F', 'R', 'B', 'L', 'F', 'R' ],
    [ 'R', 'B', 'L', 'F', 'R', 'B' ],
    [ 'B', 'L', 'F', 'R', 'B', 'L' ],
    [ 'L', 'F', 'R', 'B', 'L', 'F' ],
    [ 'F', 'R', 'B', 'L', 'F', 'R' ]
]
blockTypes.reverse()

# 0=ground level, 1=one cinderblock offset, etc
blockLevels = [
    [ 0, 0, 0, 0, 0, 0 ],
    [ 1, 1, 1, 1, 1, 1 ],
    [ 1, 2, 1, 1, 2, 1 ],
    [ 0, 1, 1, 1, 1, 0 ],
    [ 0, 0, 1, 1, 0, 0 ],
    [ 0, 0, 1, 1, 0, 0 ],
    [ 0, 0, 0, 0, 0, 0 ]
]
blockLevels.reverse()

# map between block types and yaw angles (degrees)
blockAngleMap = { 'F': 180, 'B': 0, 'R': 90, 'L': 270 }

# TODO: this is just an example
# which foot, block (row,col), offset (x,y), support
# (row,col) refer to which block
# (x,y) are offsets wrt the block center, in meters
# support is an enum indicating foot support type
#   0=heel-toe, 1=midfoot-toe, 2=heel-midfoot
footstepData = [
    [ 'left',  (0,1), (0.00, 0.00),  0 ],
    [ 'right', (0,2), (0.00, 0.00),  0 ],
    [ 'left',  (1,1), (-0.10, 0.00), 0 ],
    [ 'right', (1,2), (0.00, 0.05),  0 ],
    [ 'left',  (2,1), (0.10, -0.05), 0 ],
    [ 'right', (2,2), (0.10, 0.10),  0 ]
]

blockColor = [0.4, 0.6, 0.4]
blockColorMatched = [0.5, 0.8, 0.5]
