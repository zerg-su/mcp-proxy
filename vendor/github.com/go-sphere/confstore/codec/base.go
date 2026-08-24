package codec

import (
	"encoding/json"
	"errors"
)

type codec struct {
	encoder EncoderFunc
	decoder DecoderFunc
}

func NewCodec(encoder EncoderFunc, decoder DecoderFunc) Codec {
	return &codec{
		encoder: encoder,
		decoder: decoder,
	}
}

func (c *codec) Marshal(val any) ([]byte, error) {
	return c.encoder(val)
}

func (c *codec) Unmarshal(data []byte, val any) error {
	return c.decoder(data, val)
}

var (
	// ErrInvalidType indicates that the provided type is not supported by the codec operation.
	ErrInvalidType = errors.New("invalid type for codec operation")
	// ErrNilPointer indicates that a nil pointer was provided for marshaling, which is not allowed.
	ErrNilPointer = errors.New("nil pointer cannot be marshaled")
)

// JsonCodec creates a codec for handling JSON serialization and deserialization.
// It uses the standard library's json.Marshal and json.Unmarshal functions.
// This codec can handle any type supported by the JSON package.
func JsonCodec() Codec {
	return &codec{
		encoder: json.Marshal,
		decoder: json.Unmarshal,
	}
}

// StringCodec creates a codec for handling string and *string types.
// It converts strings to bytes directly without any transformation.
// For decoding, the target must be a *string pointer.
func StringCodec() Codec {
	return &codec{
		encoder: func(val any) ([]byte, error) {
			if str, ok := val.(string); ok {
				return []byte(str), nil
			}
			if strPtr, ok := val.(*string); ok {
				if strPtr == nil {
					return nil, ErrNilPointer
				}
				return []byte(*strPtr), nil
			}
			return nil, ErrInvalidType
		},
		decoder: func(data []byte, val any) error {
			if strPtr, ok := val.(*string); ok {
				if strPtr == nil {
					return ErrNilPointer
				}
				*strPtr = string(data)
				return nil
			}
			return ErrInvalidType
		},
	}
}
