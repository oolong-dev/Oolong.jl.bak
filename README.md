# Oolong.jl

*An actor framework for [ReinforcementLearning.jl](https://github.com/JuliaReinforcementLearning/ReinforcementLearning.jl)*

> “是非成败转头空” —— [《临江仙》](https://www.vincentpoon.com/the-immortals-by-the-river-----------------.html)
> [杨慎](https://zh.wikipedia.org/zh-hans/%E6%9D%A8%E6%85%8E)
>
> "Success or failure, right or wrong, all turn out vain." - [*The Immortals by
> the
> River*](https://www.vincentpoon.com/the-immortals-by-the-river-----------------.html),
> [Yang Shen](https://en.wikipedia.org/wiki/Yang_Shen)
> 
> (Translated by [Xu Yuanchong](https://en.wikipedia.org/wiki/Xu_Yuanchong))

## Roadmap

- [x] Figure out a set of simple primitives for running distributed
  applications.
- [ ] Apply this package to some typical RL algorithms:
  - [x] Parameter server
  - [x] Batch serving
    - [ ] Add macro to expose a http endpoint
  - [ ] A3C
  - [ ] D4PG
  - [ ] AlphaZero
  - [ ] Deep CFR
  - [ ] NFSP
  - [ ] Evolution algorithms
- [ ] Resource management across nodes
- [ ] State persistence and fault tolerance
- [ ] Configurable logging and dashboard
  - [LokiLogger.jl](https://github.com/fredrikekre/LokiLogger.jl)
  - [Stipple.jl](https://github.com/GenieFramework/Stipple.jl)

## Get Started

⚠ *This package is still under rapid development and is not registered yet.*

First install this package:

```julia
pkg> activate --temp

pkg> add https://github.com/JuliaReinforcementLearning/Oolong.jl
```

`Oolong.jl` adopts the [actor model](https://en.wikipedia.org/wiki/Actor_model) to
parallelize your existing code. One of the core APIs defined in this package is
the `@actor` macro.

```julia
using Oolong

A = @actor () -> @info "Hello World"
```

By putting the `@actor` macro before arbitrary callable object, we defined an
**actor**. And we can call it as usual:

```julia
A();
```

You'll see something like this on your screen:

```
Info:[2021-06-30 22:59:51](@/user/#1)Hello World
```

Next, let's make sure anonymous functions with positional and keyword arguments
can also work as expected:

```julia
A = @actor (msg;suffix="!") -> @info "Hello " * msg * suffix
A("World";suffix="!!!")
# Info:[2021-06-30 23:00:38](@/user/#5)Hello World!!!
```

For some functions, we are more interested in the returned value.

```julia
A = @actor msg -> "Hello " * msg
res = A("World")
```

Well, different from the general function call, a result similar to `Future` is
returned instead of the real value. We can then fetch the result with the
following syntax:

```julia
res[]
# "Hello World"
```

To maintain the internal states across different calls, we can also apply `@actor`
to a customized structure:

```julia
Base.@kwdef mutable struct Counter
    n::Int = 0
end

(c::Counter)() = c.n += 1

A = @actor Counter()

for _ in 1:10
    A()
end

n = A.n

n[]
# 10
```

Note that similar to function call, the return of `A.n` is also a `Future` like object.

### Tips

- Be careful with `self()`

## Acknowledgement

This package is mainly inspired by the following packages:

- [Actors.jl](https://github.com/JuliaActors/Actors.jl)
- [Proto.Actor](https://proto.actor/)
- [Ray](https://ray.io/)
