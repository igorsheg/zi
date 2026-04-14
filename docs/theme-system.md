# Theme system

Themes should describe semantics, not random paint buckets.

## Principles

### Semantic names over visual names

Tokens should describe what a surface is for, not what color it happens to be.

Good:
- text
- border
- warning
- background_menu

Bad:
- gray_3
- dark_blue
- modal_bg_2 if it really means a shared elevated surface

### Terminal defaults are sacred

The terminal's default foreground and background are part of the user's environment.

Only override them when the surface truly needs an explicit fill, such as elevated menus, selections, or other opaque UI.

### Surfaces need hierarchy

A durable theme model distinguishes elevation levels.

At minimum, think in terms of:
- base background
- panel/chrome
- interactive element
- floating menu/overlay

Without surface tiers, modal surfaces tend to become visually muddy and theme authors end up encoding layout bugs as one-off feature tokens.

### State beats feature sprawl

Theme tokens should describe stable states that recur across the product:
- success
- warning
- error
- info
- focused border
- muted text

Only introduce feature-specific tokens when the state is truly unique and reusable.

### Thinking should remain semantic

If reasoning level is visually surfaced, treat it as a semantic scale, not an ad-hoc styling trick.

## Themes are data

Themes should be loadable data, not hard-coded assumptions scattered through components.

A theme system is healthier when:
- the token set is stable
- defaults exist
- external themes can map into the same semantic space

## The anti-goal

The theme system should not become a second UI architecture.
It should provide a clean semantic vocabulary that the UI uses consistently.
