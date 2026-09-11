# Control Flow

Use conditions and loops to choose when code runs and how many times it repeats.

## Overview

PunPun uses brace-delimited `if` blocks and range-based `for` loops. Conditions are boolean expressions.

## Syntax

```punpun
if score > 10 {
    say("high");
} else {
    say("low");
}

for i in 0..3 {
    say(i);
}

for value in values {
    say(value);
}
```

## Runnable example

```punpun
fn classify(value: i64) -> String {
    if value > 0 {
        return "positive";
    }
    return "zero or negative";
}

launch {
    for i in 0..4 {
        say(classify(i - 1));
    }
}
```

Save as `control.pp` and run `pp run control.pp`.

## Common mistakes

- Using `=` when you mean comparison. Assignment and comparison are different operations.
- Forgetting braces around a control-flow body.
- Assuming `0..4` includes `4`. Treat the upper bound as exclusive in ordinary range loops.
- Expecting sequence iteration over every container. PunPun 1.4.5 supports `nums`, `List<T>`, and `Slice<T>`; `Map<V>` and string characters are not yet iterable.

## Next steps

Move to [Objects, Structs, and Contracts](objects.html) when you are comfortable with functions and control flow.
