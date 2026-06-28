# var vs dynamic vs Object

## Objective
Practice choosing between `var`, `Object`, `dynamic`, and `num` based on whether type safety, flexibility, or both are needed.

## Instructions
Change the **declarations** so:
- `value` can hold `String`, `int`, and `bool` but stays type-safe (requires `is` check).
- `flexible` can hold any type without compile errors (no type safety).
- `number` can hold both `int` and `double` values but stays type-safe.

## Restrictions
- Do not change the assigned values.
- Do not remove any assignment lines.
- Do not use `var` after your fix.

## Starter Code

```dart
void main() {
  // TODO 1: value should hold String, int, and bool but stay type-safe
  var value = 'Hello';
  value = 42;    // compile error
  value = true;  // compile error

  if (value is String) {
    print(value.toUpperCase());
  } else {
    print(value);
  }

  // TODO 2: flexible should hold any type without safety
  String flexible = 'Start';
  flexible = 99;
  flexible = true;
  print(flexible);

  // TODO 3: number should hold both int and double (type-safe parents)
  int number = 10;
  number = 10.5;  // compile error
  print(number);
}
```

## Expected Output

```
true
true
10.5
```
