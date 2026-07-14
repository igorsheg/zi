# Use explicit state and owned transitions

OpenZi treats every stateful behavior as a state machine at the scale appropriate to that behavior. The owner stores concrete domain data, exposes the operations that can change it, and keeps the allowed transitions in one place. Mutually exclusive modes are represented as explicit discriminated unions with domain-named fields so invalid combinations are not representable. Closed unions are handled exhaustively.

Transition decisions and side effects remain distinct. An owner admits an operation from the current state, records the transition, runs the bounded asynchronous or process effect, and then applies the corresponding success, failure, or cancellation transition. Operation identities or generations must reject stale completions where work can overlap. React effects synchronize subscriptions and owned resources; they do not form a second state machine.

This is data-oriented design, not a state-machine framework mandate. OpenZi writes concrete unions and transition functions directly. It does not introduce generic tagged-union builders, uniform `payload` envelopes, state-variant class hierarchies, command buses, or statechart libraries unless repeated concrete pressure proves they make the domain easier to read. A boolean remains appropriate for an independent binary fact; flags that jointly describe a mode must become explicit states.

Tests cover allowed and forbidden transitions at the owner boundary, including cancellation, races, bounds, and invalid external input where applicable. UI fixtures then verify that the rendered behavior follows those domain states without creating a mirrored frontend model.
