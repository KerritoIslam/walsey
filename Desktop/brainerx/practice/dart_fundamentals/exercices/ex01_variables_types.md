# Variables & Types

## Objective
Practice choosing correct primitive types and fixing values that don't match their type or purpose.

## Instructions
Fix all errors so the program prints the correct total after applying a discount.

## Restrictions
- Only change types and values — do not rename variables.
- Do not delete existing lines.

## Starter Code

```dart
void main() {
  // TODO 1: price should be 29.99 — fix both the type and the value
  int price = 30;

  // TODO 2: quantity is a count, it should be a whole number
  double quantity = 2.0;

  // TODO 3: discount is 10% — 0.1 is not an int
  int discount = 0;

  // TODO 4: The formula ignores discount. Fix it:
  // total = price * quantity * (1 - discount)
  double total = price * quantity;

  print('Total after discount: \$${total.toStringAsFixed(2)}');
}
```

## Expected Output

```
Total after discount: $53.98
```
