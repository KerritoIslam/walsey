# Type Inference with var

## Objective
Practice understanding that `var` infers a fixed type from the initial value, and choosing appropriate type modifiers when reassignment to a different type is needed.

## Instructions
The code below has compile errors because `var` fixes the inferred type. Change only the **declarations** (where `var` is written) — do not change the assignments or values.

Each variable may need a **different** solution depending on what types it needs to hold.

## Restrictions
- Do not change the assigned values.
- Do not remove any assignment lines.
- Do not use `var` after your fix.

## Starter Code

```dart
void main() {
  var name = 'Alice';
  name = 42;           // compile error: String can't hold int

  var score = 95.5;
  score = 'A';         // compile error: double can't hold String

  var items = 3;
  items = 3.0;         // compile error: int can't hold double

  var isDone = false;
  isDone = 'yes';      // compile error: bool can't hold String

  print('$name scored $score with $items items (done: $isDone)');
}
```

## Expected Output

```
42 scored A with 3.0 items (done: yes)
```
