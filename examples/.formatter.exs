# The site (lib, test) and the folder of each game.
games = for dir <- File.ls!(__DIR__), File.regular?(Path.join([__DIR__, dir, dir <> ".ex"])), do: dir

[
  inputs:
    ["{mix,.formatter}.exs", "test_helper.exs", "{lib,test}/**/*.{ex,exs}"] ++ Enum.map(games, &"#{&1}/*.{ex,exs}"),
  line_length: 120
]
