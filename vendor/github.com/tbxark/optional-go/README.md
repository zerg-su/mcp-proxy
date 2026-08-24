# optional-go

Generics-friendly Optional/Field type for Go. Enables explicit presence/absence,
ergonomic helpers, and clean JSON handling with `omitempty`.

## Quick Start

```
type User struct {
  Name string
  Age  optional.Field[int] `json:"age,omitempty"`
}

u := User{Name: "Ava"}
// Age is absent; omitted in JSON due to IsZero.
b, _ := json.Marshal(u) // {"Name":"Ava"}

// Set a value
u.Age.Set(0) // present with zero; still serialized
_ = json.Unmarshal([]byte(" {\n  \"age\": null\n} "), &u) // clears Age (absent)

// Get with defaults
age := u.Age.OrElse(18)
age2 := u.Age.OrElseGet(func() int { return 21 })

// Functional helpers
plusOne := optional.Map(u.Age, func(v int) int { return v + 1 })

// Constructors
none := optional.None[int]()
some := optional.NewField(42)
adopt := optional.AdoptPtr(&[]int{1,2,3}[0]) // advanced: shares pointer
```

## API Highlights

- New/None:
  - `NewField[T](v T)` creates a present value.
  - `NewFieldFromPtr[T](*T)` copies from pointer if non-nil.
  - `AdoptPtr[T](*T)` adopts pointer, enabling aliasing.
  - `None[T]()` creates an absent value.
- Presence:
  - `Present() bool`, `Clear()`.
  - `Get() (T, bool)`, `MustGet() T`, `ToPtr() *T` (pointer to copy), `Ref() (*T, bool)` (internal pointer).
- Defaults and flow:
  - `OrElse(T) T`, `OrElseGet(func() T) T`.
  - `If(func(T))`, `IfPresentOrElse(func(T), func())`.
- Functors:
  - `Map[T,U](Field[T], func(T) U) Field[U]`.
  - `FlatMap[T,U](Field[T], func(T) Field[U]) Field[U]`.
  - `Filter[T](Field[T], func(T) bool) Field[T]`.
- JSON:
  - Implements `json.Marshaler`/`Unmarshaler`.
  - Robust `null` handling (whitespace tolerant).
  - Implements `IsZero()` so `omitempty` omits absent fields on Go 1.20+.

## Notes

- Absent vs. present-nil: For pointer/interface `T`, both absent and present-with-nil serialize to `null` and look identical in JSON.
- Concurrency: `Field[T]` is not synchronized; guard with your own locks if sharing between goroutines.
- `ToPtr()` returns a pointer to a copy to avoid unintended aliasing. Use `Ref()` or `AdoptPtr()` only if you need shared mutation.

### License

**optional-go** is released under the MIT license. [See LICENSE](LICENSE) for details.