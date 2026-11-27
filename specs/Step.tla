---- MODULE Step ----
(***************************************************************************)
(* One step of all the boids of a world (boids:step/2, gen_boid).   *)
(* The caller asks each boid for its plan: the boid reads the world  *)
(* and calculates its new position, but it does not move. When each boid   *)
(* answered, the caller asks each boid to move (commit). Thus each boid    *)
(* calculates from the same state of the world, and the result of a  *)
(* step does not change with the order of the processes.                   *)
(*                                                                         *)
(* The position of a boid is a number here. A boid that reads the          *)
(* positions s goes to See(s).                                             *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Boids,      \* the boids of the world
    Clocks,     \* the boids that also move on their own clock (a tick that is not manual)
    Steps,      \* the steps of the caller (a bound of the model)
    None,       \* no plan
    TwoParts    \* FALSE: the fault model where a boid moves when it calculates

VARIABLES
    val,        \* the position of each boid in the world
    plan,       \* the position that each boid calculated, or None
    phase,      \* "idle", "plan", "commit"
    wait,       \* the boids that did not answer in this part of the step
    base,       \* the positions at the start of the step
    steps,      \* the steps that are done
    runs,       \* the boids whose process runs
    ticked      \* the boids that moved on their clock (one time each, a bound of the model)

vars == <<val, plan, phase, wait, base, steps, runs, ticked>>

Max(s) == CHOOSE m \in {s[b] : b \in Boids} : \A b \in Boids : s[b] <= m

\* The new position of a boid that reads the positions s.
See(s) == 1 + Max(s)

Init ==
    /\ val \in [Boids -> 0..1]
    /\ plan = [b \in Boids |-> None]
    /\ phase = "idle"
    /\ wait = {}
    /\ base = val
    /\ steps = 0
    /\ runs = Boids
    /\ ticked = {}

\* The caller starts a step: it asks each boid for its plan.
Begin ==
    /\ phase = "idle" /\ steps < Steps
    /\ phase' = "plan"
    /\ base' = val
    /\ wait' = runs
    /\ UNCHANGED <<val, plan, steps, runs, ticked>>

\* A boid calculates its new position from the world as it is now.
Plan(b) ==
    /\ phase = "plan" /\ b \in wait \cap runs
    /\ IF TwoParts
       THEN plan' = [plan EXCEPT ![b] = See(val)] /\ UNCHANGED val
       ELSE val' = [val EXCEPT ![b] = See(val)] /\ UNCHANGED plan
    /\ wait' = wait \ {b}
    /\ UNCHANGED <<phase, base, steps, runs, ticked>>

\* Each boid that runs answered: the caller asks each boid to move.
Turn ==
    /\ phase = "plan" /\ wait \cap runs = {}
    /\ phase' = "commit"
    /\ wait' = runs
    /\ UNCHANGED <<val, plan, base, steps, runs, ticked>>

\* A boid moves to the position of its plan.
Commit(b) ==
    /\ phase = "commit" /\ b \in wait \cap runs
    /\ val' = IF plan[b] /= None THEN [val EXCEPT ![b] = plan[b]] ELSE val
    /\ plan' = [plan EXCEPT ![b] = None]
    /\ wait' = wait \ {b}
    /\ UNCHANGED <<phase, base, steps, runs, ticked>>

\* Each boid that runs moved: the step is done.
End ==
    /\ phase = "commit" /\ wait \cap runs = {}
    /\ phase' = "idle"
    /\ wait' = {}
    /\ steps' = steps + 1
    /\ UNCHANGED <<val, plan, base, runs, ticked>>

\* A boid with a clock moves at its tick, at each moment.
Tick(b) ==
    /\ b \in (Clocks \cap runs) \ ticked
    /\ val' = [val EXCEPT ![b] = See(val)]
    /\ ticked' = ticked \cup {b}
    /\ UNCHANGED <<plan, phase, wait, base, steps, runs>>

\* The process of a boid stops, at each moment. The caller does not wait for it.
Stop(b) ==
    /\ b \in runs
    /\ runs' = runs \ {b}
    /\ UNCHANGED <<val, plan, phase, wait, base, steps, ticked>>

Over == phase = "idle" /\ steps = Steps /\ UNCHANGED vars

Next ==
    \/ Begin \/ Turn \/ End \/ Over
    \/ \E b \in Boids : Plan(b) \/ Commit(b) \/ Tick(b) \/ Stop(b)

\* The caller and the boids that run continue. A process can stop or not.
Work == Begin \/ Turn \/ End \/ (\E b \in Boids : Plan(b) \/ Commit(b))

Spec == Init /\ [][Next]_vars /\ WF_vars(Work)

\* --- Invariants --------------------------------------------------------

\* While the boids calculate, no boid moves.
Quiet == phase = "plan" => val = base

\* After a step, each boid is where a boid that read the world at the
\* start of the step goes. A boid whose process stopped before it moved
\* is where it was.
OneMoment ==
    (phase = "idle" /\ steps > 0) =>
        \A b \in Boids : val[b] = See(base) \/ (b \notin runs /\ val[b] = base[b])

\* --- Liveness ----------------------------------------------------------

\* Each step ends, also when processes stop during the step.
Ends == <>(phase = "idle" /\ steps = Steps)
====
