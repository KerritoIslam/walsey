# Challenge: Countdown Timer

## Objective
Combine `Stream.periodic`, `take`, `listen` with `onDone` and `onError`, and transforming stream data.

## Scenario
A fitness app uses a countdown timer. The timer emits seconds, filters to only even seconds, and handles a faulty backup timer that fails immediately.

## Instructions
- Create a `Stream.periodic` that emits `0, 1, 2, 3, 4, 5` (one per second).
- Use `take(6)` to limit emissions, then filter to keep only even numbers using `.where()`.
- Listen to the stream with `onDone` callback.
- Handle the faulty stream's error with `onError`.

## Restrictions
- Do not rename variables.
- Do not delete existing code.
- Use `Stream.periodic` for the timer.
- Use `.where()` to filter even values.

## Starter Code

```dart
void main() {
  // TODO 1: Create a stream that emits 0, 1, 2, 3, 4, 5 (one per second)
  Stream<int>? timer;

  // TODO 2: Take 6 values, then use .where() to keep only even numbers.
  // Listen with onDone that prints 'Countdown complete!'
  timer?.take(0).where((v) => true).listen(
    null,                // fix: print each received value
    onDone: () => null,  // fix: print 'Countdown complete!'
  );

  // TODO 3: Handle the faulty stream's error with onError
  Stream<int> faulty = Stream.error('Timer hardware failure');
  faulty.listen(
    (v) => print(v),
    // add onError here
  );
}
```

## Expected Output

```
Error: Timer hardware failure
0
2
4
Countdown complete!
```
