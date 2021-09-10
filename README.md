<pre>
<img src="./docs/logo.svg" alt="Oolong.jl logo" title="Oolong.jl" align="left" width="180"/>
  ____        _                     |  > 是非成败转头空
 / __ \      | |                    |  > Success or failure,
| |  | | ___ | | ___  _ __   __ _   |  > right or wrong,
| |  | |/ _ \| |/ _ \| '_ \ / _` |  |  > all turn out vain.
| |__| | (_) | | (_) | | | | (_) |  |
 \____/ \___/|_|\___/|_| |_|\__, |  |  <a href="https://www.vincentpoon.com/the-immortals-by-the-river-----------------.html">The Immortals by the River </a>
                             __/ |  |  -- <a href="https://zh.wikipedia.org/zh-hans/%E6%9D%A8%E6%85%8E">Yang Shen </a>
                            |___/   |  (Translated by <a href="https://en.wikipedia.org/wiki/Xu_Yuanchong">Xu Yuanchong</a>) 
</pre>

**Oolong.jl** is a framework for building scalable distributed applications in Julia.

## Features

- Easy to use
    Only very minimal APIs are exposed to make this package easy to use (yes, easier than [Distributed.jl](https://docs.julialang.org/en/v1/stdlib/Distributed/)).

- Non-invasive
    Users can easily extend existing packages to apply them in a cluster.

- Fault tolerance

- Auto scaling

## Get Started

⚠ *This package is still under rapid development and is not registered yet.*

First install this package:

```julia
pkg> activate --temp

pkg> add https://github.com/JuliaReinforcementLearning/Oolong.jl
```

See tests for some example usages. (TODO: move typical examples here when APIs are stabled)

## Examples

- Batch evaluation.
- AlphaZero
- Parameter server
- Parameter search

Please contact us if you have a concrete scenario but not sure how to use this package!

## Deployment

### Local Machines

### K8S

## Roadmap

1. Stage 1
    1. Stabilize API
        1. ☑️ `p::PotID = @pot tea [prop=value...]`, define a container over any callable object.
        2. ☑️ `(p::PotID)(args...;kw...)`, which behaves just like `tea(args...;kw...)`, except that it's an async call, at most once delievery, a `Promise` is returned.
        3. ☑️ `msg |> p::PotID` similar to the above one, except that nothing is returned.
        4. ☑️ `(p::PotID).prop`, async call, at most once delievery, return the `prop` of the inner `tea`.
        5. 🧐 `-->`, `<--`, define a streaming pipeline.
        6. 🧐 timed wait on `Promise`.
    2. Features
        1. ☑️ Logging. All messages are sent to primary node by default.
        2. 🧐 RemoteREPL
        3. ☑️ CPU/GPU allocation
        4. 🧐 Auto intall+using dependencies
        5. ☑️ Global configuration
    3.  Example usages
        1. 🧐 Parameter search
        2. 🧐 Batch evaluation.
        3. 🧐 AlphaZero
        4. 🧐 Parameter server
2. Stage 2
    1. Auto1.scaling. Allow workers join/exit?
        1. 🧐 Custom cluster manager
    2. Dashboard
        1. 🧐 [grafana](https://grafana.com/)
    3. Custom Logger
        1. 🧐 [LokiLogger.jl](https://github.com/fredrikekre/LokiLogger.jl)
        2. 🧐 [Stipple.jl](https://github.com/GenieFramework/Stipple.jl)
    4. Tracing
1. Stage 3
    1. Drop out Distributed.jl?
        1. 🧐 `Future` will transfer the ownership of the underlying data to the caller. Not very efficient when the data is passed back and forth several times in its life circle.
    2. 🧐 differentiate across pots?
    3. 🧐 Python client (transpile, pickle)
    4. 🧐 K8S
    5. 🧐 JuliaHub
    6. 🧐 AWS
    7. 🧐 Azure

## Design

### Workflow

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
  |  | Promise |                    |
  |  +---------+                    |
  +---------------------------------+
```

A `Pot` is mainly a container of an arbitrary object (`tea`) which is instantiated by calling a parameterless function. Whenever a `Pot` receives a `flavor`, the water in the `Pot` is *boiled* first (a `task` is created to process `tea` and `flavor`) if it is cool (the previous `task` was exited by accident or on demand). Some `Pot`s may have a few specific `require`ments (the number of cpu, gpu). If those requirements can not be satisfied, the `Pot` will be pending to wait for new resources. Users can define how `tea` and `flavor` are processed through multiple dispatch on `process(tea, flavor)`. In some `task`s, users may create many other `Pot`s whose references (`PotID`) are stored in `Children`.  A `PotID` is simply a path used to locate a `Pot`.

### Decisions

The following design decisions need to be reviewed continuously.

1. Each `Pot` can only be created inside of another `Pot`, which forms a child-parent relation. If no `Pot` is found in the `current_task()`, the parent is bind to `/user` by default.

### FAQ

## Acknowledgement

This package is mainly inspired by the following projects:

- [Orleans](https://github.com/dotnet/orleans)
- [Proto.Actor](https://proto.actor/)
- [Ray](https://ray.io/)
- [Actors.jl](https://github.com/JuliaActors/Actors.jl)
