# Oolong.jl

*An actor framework for [~~ReinforcementLearning.jl~~](https://github.com/JuliaReinforcementLearning/ReinforcementLearning.jl) <ins>distributed computing</ins> in Julia.*

> “是非成败转头空” —— [《临江仙》](https://www.vincentpoon.com/the-immortals-by-the-river-----------------.html)
> [杨慎](https://zh.wikipedia.org/zh-hans/%E6%9D%A8%E6%85%8E)
>
> "Success or failure, right or wrong, all turn out vain." - [*The Immortals by
> the
> River*](https://www.vincentpoon.com/the-immortals-by-the-river-----------------.html),
> [Yang Shen](https://en.wikipedia.org/wiki/Yang_Shen)
> 
> (Translated by [Xu Yuanchong](https://en.wikipedia.org/wiki/Xu_Yuanchong))


## Features

- Non-invasive
  Users can easily extend existing packages to apply them in a cluster.

- Simple API
  Only very minimal APIs are provided to ease the usage.

## Roadmap

- Stage 1
  - [ ] Stabilize API
    - [x] `@pot tea [prop=value...]`, define a container over any callable object.
    - [x] `(p::PotID)(args...;kw...)`, async call, at most once delievery, a `Promise` is returned.
    - [x] `msg |> p::PotID`, async call, at most once delievery, no return.
    - [x] `(p::PotID).prop`, async call, at most once delievery, return the `prop` of the inner `tea`.
    - [ ] `-->`, `<--`, define a streaming pipeline.
  - [ ] Features
    - [x] Logging. All messages are sent to primary node by default.
    - [ ] RemoteREPL
    - [x] CPU/GPU allocation
    - [ ] Auto intall+using dependencies
  - [ ] Example usages
- Stage 2
  - [ ] Auto-scaling. Allow workers join/exit?
    - [ ] Custom cluster manager
  - [ ] Dashboard
    - [ ] [grafana](https://grafana.com/)
  - [ ] Custom Logger
    - [LokiLogger.jl](https://github.com/fredrikekre/LokiLogger.jl)
    - [Stipple.jl](https://github.com/GenieFramework/Stipple.jl)
  - [ ] Tracing
- Stage 3
  - [ ] Drop out Distributed.jl?
  - [ ] K8S
  - [ ] differentiate accross pots?
  - [ ] Python client (transpile, pickle)

## Design

```
      +--------+
      | Flavor |
      +--------+
          |
          V         +-------------+
      +---+---+     | Pot         |
      | PotID |<===>|             |
      +---+---+     |  PotID      |
          |         |  () -> Tea  |
          |         |  require    |
          |         +-------------+
  +-------|-------------------------+
  |       V        boiled somewhere |
  |  +----+----+                    |
  |  | Channel |                    |
  |  +----+----+                    |
  |       |                         |
  |       V        +-----------+    |
  |    +--+--+     | PotState  |    |
  |    | Tea |<===>|           |    |
  |    +--+--+     |  Children |    |
  |       |        +-----------+    |
  |       V                         |
  |  +----+----+                    |
  |  | Future  |                    |
  |  +---------+                    |
  +---------------------------------+
```

A `Pot` is mainly a container of an arbitrary object (`tea`) which is instantiated by calling a parameterless function. Whenever a `Pot` receives a `flavor` through the `channel`, the water in the `Pot` is *boiled* first (a `task` to process `tea` and `flavor` is created) if it is cool (the previous `task` was exited by accident or on demand). Users can define how `tea` and `flavor` are processed through multiple dispatch on `process(tea, flavor)`. In some `task`s, users may create many other `Pot`s whose references (`PotID`) are stored in `Children`.  A `PotID` is simply a path used to locate a `Pot`.

## Get Started

⚠ *This package is still under rapid development and is not registered yet.*

First install this package:

```julia
pkg> activate --temp

pkg> add https://github.com/JuliaReinforcementLearning/Oolong.jl
```


### FAQ

## Acknowledgement

This package is mainly inspired by the following packages:

- [Proto.Actor](https://proto.actor/)
- [Ray](https://ray.io/)
- [Orleans](https://github.com/dotnet//orleans)
- [Actors.jl](https://github.com/JuliaActors/Actors.jl)
