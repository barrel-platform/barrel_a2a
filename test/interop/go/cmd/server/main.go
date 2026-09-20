// A2A Go SDK server driven by the CT suite.
//
// usage: server <port> [jsonrpc|rest|both]
//
// Serves an agent whose behaviour mirrors barrel_a2a_test_agent for the
// inputs the suite uses, over the official SDK's a2asrv handlers:
//
//	echo: X    working, artifact X, completed
//	stream     working, two artifact chunks (second appends), completed
//	ask        input_required; a follow-up on the same task completes
//	           with artifact `thanks: <text>`
//	direct     a direct Message reply, no task
//	slow N     sleeps N ms, then completes with `done`
//	cancel-me  working, then waits until cancelled
//
// JSON-RPC is served at /a2a/jsonrpc and REST under /a2a/v1; the card at
// /.well-known/agent-card.json. Prints `READY <port>` on stdout once the
// listener is up, which is the whole startup contract with the suite.
//
// This mirrors test/interop/server.py and test/interop/js/server.mjs.
// Keep the three in step: the suite runs the same cases against each.
package main

import (
	"context"
	"fmt"
	"iter"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
)

const (
	jsonrpcPath = "/a2a/jsonrpc"
	restPrefix  = "/a2a/v1"
)

func messageText(m *a2a.Message) string {
	if m == nil {
		return ""
	}
	var b strings.Builder
	for _, p := range m.Parts {
		if p == nil {
			continue
		}
		if text, ok := p.Content.(a2a.Text); ok {
			b.WriteString(string(text))
		}
	}
	return b.String()
}

func status(ec *a2asrv.ExecutorContext, state a2a.TaskState, msg *a2a.Message) a2a.Event {
	now := time.Now().UTC()
	return &a2a.TaskStatusUpdateEvent{
		TaskID:    ec.TaskID,
		ContextID: ec.ContextID,
		Status:    a2a.TaskStatus{State: state, Message: msg, Timestamp: &now},
	}
}

func artifact(ec *a2asrv.ExecutorContext, text, id, name string, appnd, last bool) a2a.Event {
	artifactID := a2a.ArtifactID(id)
	if id == "" {
		artifactID = a2a.NewArtifactID()
	}
	return &a2a.TaskArtifactUpdateEvent{
		TaskID:    ec.TaskID,
		ContextID: ec.ContextID,
		Artifact: &a2a.Artifact{
			ID:         artifactID,
			Name:       name,
			Parts:      a2a.ContentParts{a2a.NewTextPart(text)},
		},
		Append:    appnd,
		LastChunk: last,
	}
}

func newTask(ec *a2asrv.ExecutorContext) *a2a.Task {
	now := time.Now().UTC()
	return &a2a.Task{
		ID:        ec.TaskID,
		ContextID: ec.ContextID,
		Status:    a2a.TaskStatus{State: a2a.TaskStateSubmitted, Timestamp: &now},
		History:   []*a2a.Message{ec.Message},
	}
}

// execute mirrors barrel_a2a_test_agent's dispatch/3.
func execute(ctx context.Context, ec *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		text := messageText(ec.Message)

		// A follow-up on a paused task answers it, whatever it says.
		// No task snapshot first: the stored one still reads
		// `input_required', and a non-streaming send would report that
		// stale status as the result.
		if ec.StoredTask != nil && ec.StoredTask.Status.State == a2a.TaskStateInputRequired {
			if !yield(artifact(ec, "thanks: "+text, "", "", false, false), nil) {
				return
			}
			yield(status(ec, a2a.TaskStateCompleted, nil), nil)
			return
		}

		if text == "direct" {
			yield(a2a.NewMessage(a2a.MessageRoleAgent, a2a.NewTextPart("direct reply")), nil)
			return
		}

		task := ec.StoredTask
		if task == nil {
			task = newTask(ec)
		}
		if !yield(task, nil) {
			return
		}

		switch {
		case strings.HasPrefix(text, "echo: "):
			if !yield(status(ec, a2a.TaskStateWorking, nil), nil) {
				return
			}
			if !yield(artifact(ec, strings.TrimPrefix(text, "echo: "), "", "", false, false), nil) {
				return
			}
			yield(status(ec, a2a.TaskStateCompleted, nil), nil)

		case text == "stream":
			starting := a2a.NewMessage(a2a.MessageRoleAgent, a2a.NewTextPart("starting"))
			if !yield(status(ec, a2a.TaskStateWorking, starting), nil) {
				return
			}
			if !yield(artifact(ec, "part one ", "a1", "out", false, false), nil) {
				return
			}
			if !yield(artifact(ec, "part two", "a1", "out", true, true), nil) {
				return
			}
			yield(status(ec, a2a.TaskStateCompleted, nil), nil)

		case text == "ask":
			more := a2a.NewMessage(a2a.MessageRoleAgent, a2a.NewTextPart("more?"))
			yield(status(ec, a2a.TaskStateInputRequired, more), nil)

		case strings.HasPrefix(text, "slow "):
			if !yield(status(ec, a2a.TaskStateWorking, nil), nil) {
				return
			}
			ms, _ := strconv.Atoi(strings.TrimPrefix(text, "slow "))
			select {
			case <-time.After(time.Duration(ms) * time.Millisecond):
			case <-ctx.Done():
				return
			}
			if !yield(artifact(ec, "done", "", "", false, false), nil) {
				return
			}
			yield(status(ec, a2a.TaskStateCompleted, nil), nil)

		case text == "cancel-me":
			// Cancellation arrives as a cancelled context; the handler
			// publishes the canceled status itself.
			if !yield(status(ec, a2a.TaskStateWorking, nil), nil) {
				return
			}
			<-ctx.Done()

		default:
			if !yield(status(ec, a2a.TaskStateWorking, nil), nil) {
				return
			}
			if !yield(artifact(ec, "unknown: "+text, "", "", false, false), nil) {
				return
			}
			yield(status(ec, a2a.TaskStateCompleted, nil), nil)
		}
	}
}

func buildCard(port int, binding string) *a2a.AgentCard {
	base := fmt.Sprintf("http://127.0.0.1:%d", port)
	var interfaces []*a2a.AgentInterface
	if binding == "jsonrpc" || binding == "both" {
		interfaces = append(interfaces,
			a2a.NewAgentInterface(base+jsonrpcPath, a2a.TransportProtocolJSONRPC))
	}
	if binding == "rest" || binding == "both" {
		interfaces = append(interfaces,
			a2a.NewAgentInterface(base+restPrefix, a2a.TransportProtocolHTTPJSON))
	}
	return &a2a.AgentCard{
		Name:                "Go Test Agent",
		Description:         "SDK agent mirroring barrel_a2a_test_agent",
		Version:             "1.2.3",
		SupportedInterfaces: interfaces,
		DefaultInputModes:   []string{"text/plain"},
		DefaultOutputModes:  []string{"text/plain"},
		Capabilities:        a2a.AgentCapabilities{Streaming: true},
		Skills: []a2a.AgentSkill{{
			ID:          "echo",
			Name:        "Echo",
			Description: "Echoes text back",
			Tags:        []string{"test"},
		}},
	}
}

func main() {
	args := os.Args[1:]
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "usage: server <port> [jsonrpc|rest|both]")
		os.Exit(2)
	}
	port, err := strconv.Atoi(args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, "usage: server <port> [jsonrpc|rest|both]")
		os.Exit(2)
	}
	binding := "both"
	if len(args) > 1 {
		binding = args[1]
	}
	if binding != "jsonrpc" && binding != "rest" && binding != "both" {
		fmt.Fprintln(os.Stderr, "usage: server <port> [jsonrpc|rest|both]")
		os.Exit(2)
	}

	card := buildCard(port, binding)
	requestHandler := a2asrv.NewHandler(a2asrv.AgentExecutorFunc(execute))

	mux := http.NewServeMux()
	mux.Handle(a2asrv.WellKnownAgentCardPath, a2asrv.NewStaticAgentCardHandler(card))
	if binding == "jsonrpc" || binding == "both" {
		mux.Handle(jsonrpcPath, a2asrv.NewJSONRPCHandler(requestHandler))
	}
	if binding == "rest" || binding == "both" {
		mux.Handle(restPrefix+"/", http.StripPrefix(restPrefix, a2asrv.NewRESTHandler(requestHandler)))
	}

	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("READY %d\n", port)
	os.Stdout.Sync()
	if err := http.Serve(listener, mux); err != nil {
		fmt.Fprintf(os.Stderr, "serve: %v\n", err)
	}
}
