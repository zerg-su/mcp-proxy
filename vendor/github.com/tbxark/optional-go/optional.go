package optional

import (
	"bytes"
	"encoding/json"
	"fmt"
)

type Field[T any] struct {
	value *T
}

func NewField[T any](v T) Field[T] {
	return Field[T]{&v}
}

func NewFieldFromPtr[T any](v *T) Field[T] {
	if v == nil {
		return Field[T]{}
	}
	return NewField[T](*v)
}

// AdoptPtr creates a Field[T] that references the provided pointer directly.
// Mutations through the returned reference will affect the original value.
func AdoptPtr[T any](v *T) Field[T] {
	return Field[T]{value: v}
}

func (i *Field[T]) Set(v T) {
	i.value = &v
}

func (i *Field[T]) ToPtr() *T {
	if !i.Present() {
		return nil
	}
	v := *i.value
	return &v
}

// Ref returns the internal pointer and whether it is present.
// Mutating through the returned pointer (when ok) affects the stored value.
func (i *Field[T]) Ref() (*T, bool) {
	if !i.Present() {
		return nil, false
	}
	return i.value, true
}

func (i *Field[T]) Get() (T, bool) {
	if !i.Present() {
		var zero T
		return zero, false
	}
	return *i.value, true
}

func (i *Field[T]) MustGet() T {
	if !i.Present() {
		panic("value not present")
	}
	return *i.value
}

func (i *Field[T]) Present() bool {
	return i.value != nil
}

func (i *Field[T]) OrElse(v T) T {
	if i.Present() {
		return *i.value
	}
	return v
}

// OrElseGet returns the contained value if present, otherwise uses supplier.
func (i *Field[T]) OrElseGet(supplier func() T) T {
	if i.Present() {
		return *i.value
	}
	return supplier()
}

func (i *Field[T]) If(fn func(T)) {
	if i.Present() {
		fn(*i.value)
	}
}

// IfPresentOrElse executes fn if present, otherwise elseFn.
func (i *Field[T]) IfPresentOrElse(fn func(T), elseFn func()) {
	if i.Present() {
		fn(*i.value)
		return
	}
	elseFn()
}

// Clear marks the field as absent.
func (i *Field[T]) Clear() {
	i.value = nil
}

// IsZero enables json omitempty to treat an absent field as zero.
func (i Field[T]) IsZero() bool { return !i.Present() }

// None returns an absent Field[T].
func None[T any]() Field[T] { return Field[T]{} }

func (i *Field[T]) MarshalJSON() ([]byte, error) {
	if i.Present() {
		// Marshal the underlying value directly.
		return json.Marshal(*i.value)
	}
	return json.Marshal(nil)
}

func (i *Field[T]) UnmarshalJSON(data []byte) error {
	if bytes.Equal(bytes.TrimSpace(data), []byte("null")) {
		i.value = nil
		return nil
	}
	var value T
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	i.value = &value
	return nil
}

// String returns a human-friendly representation for diagnostics.
func (i Field[T]) String() string {
	if !i.Present() {
		return "<none>"
	}
	return fmt.Sprintf("%v", *i.value)
}

// Map transforms the Field[T] to Field[U] using f when present.
func Map[T, U any](in Field[T], f func(T) U) Field[U] {
	if !in.Present() {
		return None[U]()
	}
	return NewField(f(*in.value))
}

// FlatMap transforms the Field[T] to Field[U] using f when present.
func FlatMap[T, U any](in Field[T], f func(T) Field[U]) Field[U] {
	if !in.Present() {
		return None[U]()
	}
	return f(*in.value)
}

// Filter returns the same field if the predicate holds, otherwise None.
func Filter[T any](in Field[T], pred func(T) bool) Field[T] {
	if !in.Present() {
		return in
	}
	if pred(*in.value) {
		return in
	}
	return None[T]()
}
