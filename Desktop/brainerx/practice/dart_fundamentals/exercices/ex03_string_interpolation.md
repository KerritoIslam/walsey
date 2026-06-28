# String Interpolation

## Objective
Practice using `$variable` and `${expression}` interpolation correctly, including arithmetic expressions inside strings.

## Instructions
Fix the print statements so they use proper string interpolation and produce the expected output.

## Restrictions
- Do not use `+` for concatenation.
- Do not rename variables.
- Use `${}` for expressions.

## Starter Code

```dart
void main() {
  String item = 'Coffee';
  int qty = 3;
  double price = 4.99;
  double tax = 0.08;

  // TODO 1: Fix — variables are not interpolated (missing $)
  print('Item: item, Quantity: qty, Unit Price: price');

  // TODO 2: Calculate subtotal and total using expression interpolation
  double subtotal = qty * price;
  double total = subtotal * (1 + tax);
  print('Subtotal: \$subtotal');
  print('Total with tax: \$total');

  // TODO 3: Combine everything into one line with proper interpolation
  // Expected: "Coffee x 3 = $14.97 (total with tax: $16.17)"
  print('item x qty = \$subtotal (total with tax: \$total)');
}
```

## Expected Output

```
Item: Coffee, Quantity: 3, Unit Price: 4.99
Subtotal: $14.97
Total with tax: $16.17
Coffee x 3 = $14.97 (total with tax: $16.17)
```
