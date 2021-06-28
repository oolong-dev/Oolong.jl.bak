#=

# Design Doc

- Each node *usually* creates ONE processor.
- Each processor has ONE `LocalScheduler`
- Each `LocalScheduler` sends its available resources to the global `Scheduler` on the driver processor periodically.
- `LocalScheduler` tries to initialize actors on the local processor when available resource meets. Otherwise, send the actor initializer to the global `Scheduler`.
- If there's no resource matches, the actor is put into the `StagingArea` and will be reschedulered periodically.

Auto scaling:

- When the whole cluster is under presure, the global `Scheduler` may send request to claim for more resources.
- When most nodes are idle, the global `Scheduler` may ask some nodes to exit and reschedule the actors on it.
=#