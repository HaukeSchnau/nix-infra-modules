// Command project-runtime runs Project actions, answers runtime context queries
// for release and development instances, and plans host release compatibility.
//
//	project-runtime run --config FILE [action [arguments...]]
//	project-runtime activate --config FILE
//	project-runtime context --config FILE <query...>
//	project-runtime plan-release --host FILE --candidate FILE
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
)

// Exit statuses follow sysexits: usage, data, unavailable, and OS errors.
const (
	exitUsage       = 64
	exitData        = 65
	exitUnavailable = 66
	exitOSError     = 69
)

type runtimeFailure struct {
	status  int
	message string
}

func fail(status int, format string, arguments ...any) {
	panic(runtimeFailure{status: status, message: fmt.Sprintf(format, arguments...)})
}

// decodeStrict decodes exactly one JSON value, rejecting unknown struct fields
// and keeping numbers exact.
func decodeStrict(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("multiple JSON values")
	}
	return nil
}

func loadFile(path string, label string, target any) {
	data, err := os.ReadFile(path)
	if err != nil {
		fail(exitData, "%s %s: %v", label, path, err)
	}
	if err := decodeStrict(data, target); err != nil {
		fail(exitData, "%s %s: %v", label, path, err)
	}
}

func sortedKeys[V any](values map[string]V) []string {
	result := make([]string, 0, len(values))
	for name := range values {
		result = append(result, name)
	}
	sort.Strings(result)
	return result
}

// option removes `--name VALUE` from arguments and returns the value.
func option(arguments []string, name string) ([]string, string) {
	for index, argument := range arguments {
		if argument == name {
			if index+1 >= len(arguments) {
				fail(exitUsage, "%s requires a value", name)
			}
			rest := append(append([]string{}, arguments[:index]...), arguments[index+2:]...)
			return rest, arguments[index+1]
		}
	}
	return arguments, ""
}

func loadConfig(arguments []string) (config, []string) {
	rest, path := option(arguments, "--config")
	if path == "" {
		fail(exitUsage, "--config is required")
	}
	var value config
	loadFile(path, "runtime configuration", &value)
	value.validate()
	return value, rest
}

func run(arguments []string) int {
	if len(arguments) == 0 {
		fail(exitUsage, "usage: project-runtime run|activate|context|plan-release ...")
	}
	switch arguments[0] {
	case "run":
		configuration, rest := loadConfig(arguments[1:])
		action := configuration.DefaultAction
		if len(rest) > 0 {
			action, rest = rest[0], rest[1:]
		}
		if action == "" {
			fail(exitUsage, "this Project runtime has no default action")
		}
		return executeAction(configuration, action, configuration.Actions[action], rest)
	case "activate":
		configuration, _ := loadConfig(arguments[1:])
		if configuration.Activation == "" {
			fail(exitUsage, "this Release has no activation action")
		}
		return executeAction(configuration, "activation", configuration.Activation, nil)
	case "context":
		configuration, rest := loadConfig(arguments[1:])
		return contextQuery(configuration, rest)
	case "plan-release":
		rest, host := option(arguments[1:], "--host")
		rest, candidate := option(rest, "--candidate")
		if host == "" || candidate == "" || len(rest) != 0 {
			fail(exitUsage, "usage: project-runtime plan-release --host FILE --candidate FILE")
		}
		return printPlan(host, candidate)
	default:
		fail(exitUsage, "unknown command: %s", arguments[0])
	}
	return 0
}

func executeMain() (status int) {
	defer func() {
		if recovered := recover(); recovered != nil {
			failure, ok := recovered.(runtimeFailure)
			if !ok {
				panic(recovered)
			}
			fmt.Fprintf(os.Stderr, "project-runtime: %s\n", failure.message)
			status = failure.status
		}
	}()
	return run(os.Args[1:])
}

func main() {
	os.Exit(executeMain())
}
