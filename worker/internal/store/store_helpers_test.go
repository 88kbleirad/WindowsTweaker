package store

import (
	"errors"
	"os"
)

func writeFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o600)
}

func errorsAs(err error, target **StoreError) bool {
	return errors.As(err, target)
}
