# Challenge: Bank Transfer System

## Objective
Combine custom exceptions, `throw`, `try`/`catch` with `on`, and `finally` to build robust payment processing.

## Scenario
A banking system processes transfers. Invalid amounts should throw typed exceptions, card parsing errors must be caught separately, and every transaction must log an audit trail.

## Instructions
- Throw a `PaymentException` (provided) instead of printing.
- Use `on` to catch `FormatException` separately.
- Use `finally` to print `'--- Transaction ended ---'` after each attempt.

## Restrictions
- Do not rename variables, functions, or classes.
- Do not delete existing code.
- Do not use `Exception` directly — use the provided `PaymentException`.

## Starter Code

```dart
class PaymentException {
  final String code;
  final String message;
  PaymentException(this.code, this.message);
  @override
  String toString() => '[$code] $message';
}

bool transfer(String from, String to, double amount) {
  if (amount <= 0) {
    // TODO 1: Throw a PaymentException with code 'AMT' and message 'Amount must be positive'
    print('Amount must be positive'); // not good enough — execution continues!
  }
  if (amount > 10000) {
    throw PaymentException('LIMIT', 'Transfer limit exceeded');
  }
  print('Transferred \$$amount from $from to $to');
  return true;
}

double parseAmount(String input) {
  // TODO 2: This can throw FormatException — let it propagate (the caller handles it)
  return double.parse(input);
}

void main() {
  List<String> operations = [
    'process:-50:Alice:Bob',
    'process:999999:Alice:Bob',
    'parse:not-a-number',
  ];

  for (var op in operations) {
    // TODO 3: Wrap in try/catch. Catch PaymentException, FormatException,
    // then any other exception. Add finally for audit log.
    var parts = op.split(':');
    if (parts[0] == 'process') {
      double amt = double.parse(parts[1]);
      transfer(parts[2], parts[3], amt);
    } else if (parts[0] == 'parse') {
      parseAmount(parts[1]);
    }
  }
}
```

## Expected Output

```
[AMT] Amount must be positive
--- Transaction ended ---
[LIMIT] Transfer limit exceeded
--- Transaction ended ---
FormatException: Invalid double
--- Transaction ended ---
```
