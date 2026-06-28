# Null Safety — late Keyword

## Objective
Practice using `late` for fields initialized after construction, including multiple fields and ensuring they are initialized before use.

## Instructions
- Add `late` to fields that are set in `loadSaveData()`, not in the constructor.
- Add a safety check so `showSummary()` throws a clear error if called before `loadSaveData()`.

## Restrictions
- Do not rename variables, functions, or classes.
- Do not delete existing code.
- Do not make fields nullable.

## Starter Code

```dart
class Game {
  final String title;
  String highScore;      // TODO 1: set in loadSaveData()
  List<String> players;  // TODO 2: also set in loadSaveData()

  Game(this.title);

  void loadSaveData() {
    highScore = '9999';
    players = ['Alice', 'Bob'];
  }

  // TODO 3: Add a boolean flag _loaded that starts false and becomes true
  // in loadSaveData(). Check it in showSummary().
  void showSummary() {
    // Crash-safe: only access late fields if data is loaded
    print('$title — High score: $highScore');
    print('Players: $players');
  }
}

void main() {
  Game g = Game('Pac-Man');
  g.showSummary();   // TODO 4: Fix — this is called BEFORE loadSaveData()
  g.loadSaveData();
}
```

## Expected Output

```
Data not loaded
Pac-Man — High score: 9999
Players: [Alice, Bob]
```
