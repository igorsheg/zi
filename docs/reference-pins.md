# Reference pins

Inspected on 2026-07-16:

| Repository                | Commit                 | Use                                                       |
| ------------------------- | ---------------------- | --------------------------------------------------------- |
| `earendil-works/pi`       | `0e6909f0` (`v0.80.6`) | lower-level dependencies and coding-agent behavior        |
| `withastro/flue`          | `dbc9b05c`             | example of direct `pi-ai`/`pi-agent-core` integration     |
| `anomalyco/opentui`       | `5d57e27e` (`v0.4.3`)  | terminal implementation                                   |
| `anomalyco/opencode`      | `cb8be9ba1`            | production OpenTUI application patterns                   |
| `anomalyco/opencode` `v2` | `4678bd104`            | hot-path, keymap, loading, and render-scaling patterns    |
| `xai-org/grok-build`      | `c68e39f`              | session scaling, persistence, and lifecycle failure cases |

Pi remains the coding-agent architecture and observable behavior reference. Grok Build is a secondary source for scale and failure-case lessons; its ACP, actor, remote-session, and multi-agent architecture is not a parity target.

Refresh these pins deliberately when dependency versions change. They document what was inspected; package versions in `package.json` are the build inputs.
