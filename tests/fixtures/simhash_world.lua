-- a small world for the state hash golden test (T1.5): constructions, depots, nodes, edges, lines, vehicles
for i = 1, 6 do
  WORLD[200 + i] = { CONSTRUCTION = { fileName = "station" .. i .. ".con", transf = { [13] = 100 * i, [14] = 50 * i, [15] = 1.5 * i }, depots = {}, stations = {}, params = { a = i } } }
  WORLD[300 + i] = { BASE_NODE = { position = { x = 10 * i, y = 3 * i, z = 0.5 } } }
  WORLD[400 + i] = { LINE = { stops = {} } }
  WORLD[500 + i] = { TRANSPORT_VEHICLE = { line = 400 + i } }
end
for i = 1, 5 do
  WORLD[600 + i] = { BASE_EDGE = { node0 = 300 + i, node1 = 301 + i, objects = {}, edgeDecorations = {} } }
end
