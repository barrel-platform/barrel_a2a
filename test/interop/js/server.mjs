// A2A JavaScript SDK server driven by the CT suite.
//
// usage: server.mjs <port> [jsonrpc|rest|both]
//
// Serves an agent whose behaviour mirrors barrel_a2a_test_agent for the
// inputs the suite uses, over the official SDK's express handlers:
//
//   echo: X    working, artifact X, completed
//   stream     working, two artifact chunks (second appends), completed
//   ask        input_required; a follow-up on the same task completes
//              with artifact `thanks: <text>`
//   direct     a direct Message reply, no task
//   slow N     sleeps N ms, then completes with `done`
//   cancel-me  working, then waits until cancelled
//
// JSON-RPC is served at /a2a/jsonrpc and REST under /a2a/v1; the card at
// /.well-known/agent-card.json. Prints `READY <port>` on stdout once the
// listener is up, which is the whole startup contract with the suite.
//
// This mirrors test/interop/server.py. Keep the two in step: the suite
// runs the same cases against both.

import express from 'express';

import { A2A_PROTOCOL_VERSION, AGENT_CARD_PATH, Role, TaskState } from '@a2a-js/sdk';
import { AgentEvent, DefaultRequestHandler, InMemoryTaskStore } from '@a2a-js/sdk/server';
import {
  agentCardHandler,
  jsonRpcHandler,
  restHandler,
  UserBuilder,
} from '@a2a-js/sdk/server/express';

const JSONRPC_PATH = '/a2a/jsonrpc';
const REST_PREFIX = '/a2a/v1';

const textPart = (value) => ({
  content: { $case: 'text', value },
  metadata: undefined,
  filename: '',
  mediaType: 'text/plain',
});

const messageText = (message) => {
  const part = (message?.parts ?? []).find((p) => p.content?.$case === 'text');
  return part?.content?.$case === 'text' ? part.content.value : '';
};

const agentMessage = (taskId, contextId, text) => ({
  role: Role.ROLE_AGENT,
  messageId: crypto.randomUUID(),
  parts: [textPart(text)],
  taskId,
  contextId,
  extensions: [],
  metadata: {},
  referenceTaskIds: [],
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class TestAgentExecutor {
  // Cancellation is cooperative: cancelTask records the id and the
  // `cancel-me` loop notices. The same pattern as the SDK's own sample.
  #cancelled = new Set();

  cancelTask = async (taskId, eventBus) => {
    this.#cancelled.add(taskId);
    eventBus.publish(
      AgentEvent.statusUpdate({
        taskId,
        contextId: this.#contexts.get(taskId) ?? '',
        status: {
          state: TaskState.TASK_STATE_CANCELED,
          timestamp: new Date().toISOString(),
          message: undefined,
        },
        metadata: {},
      }),
    );
  };

  #contexts = new Map();

  #status(eventBus, taskId, contextId, state, message) {
    eventBus.publish(
      AgentEvent.statusUpdate({
        taskId,
        contextId,
        status: { state, timestamp: new Date().toISOString(), message },
        metadata: {},
      }),
    );
  }

  #artifact(eventBus, taskId, contextId, text, opts = {}) {
    eventBus.publish(
      AgentEvent.artifactUpdate({
        taskId,
        contextId,
        artifact: {
          artifactId: opts.artifactId ?? crypto.randomUUID(),
          name: opts.name ?? '',
          description: '',
          parts: [textPart(text)],
          metadata: undefined,
          extensions: [],
        },
        append: opts.append ?? false,
        lastChunk: opts.lastChunk ?? false,
        metadata: undefined,
      }),
    );
  }

  async execute(requestContext, eventBus) {
    const { userMessage, task: existing, taskId, contextId } = requestContext;
    const text = messageText(userMessage);
    this.#contexts.set(taskId, contextId);

    // A follow-up on a paused task answers it, whatever it says.
    if (existing && existing.status?.state === TaskState.TASK_STATE_INPUT_REQUIRED) {
      eventBus.publish(AgentEvent.task(existing));
      this.#artifact(eventBus, taskId, contextId, `thanks: ${text}`);
      this.#status(eventBus, taskId, contextId, TaskState.TASK_STATE_COMPLETED);
      eventBus.finished();
      return;
    }

    if (text === 'direct') {
      eventBus.publish(AgentEvent.message(agentMessage(undefined, contextId, 'direct reply')));
      eventBus.finished();
      return;
    }

    // Every turn must open with a task or a message event.
    eventBus.publish(
      AgentEvent.task(
        existing ?? {
          id: taskId,
          contextId,
          status: {
            state: TaskState.TASK_STATE_SUBMITTED,
            timestamp: new Date().toISOString(),
            message: undefined,
          },
          artifacts: [],
          history: [userMessage],
          metadata: userMessage.metadata,
        },
      ),
    );

    try {
      if (text.startsWith('echo: ')) {
        this.#status(eventBus, taskId, contextId, TaskState.TASK_STATE_WORKING);
        this.#artifact(eventBus, taskId, contextId, text.slice('echo: '.length));
        this.#status(eventBus, taskId, contextId, TaskState.TASK_STATE_COMPLETED);
      } else if (text === 'stream') {
        this.#status(
          eventBus,
          taskId,
          contextId,
          TaskState.TASK_STATE_WORKING,
          agentMessage(taskId, contextId, 'starting'),
        );
        this.#artifact(eventBus, taskId, contextId, 'part one ', {
          artifactId: 'a1',
          name: 'out',
        });
        this.#artifact(eventBus, taskId, contextId, 'part two', {
          artifactId: 'a1',
          name: 'out',
          append: true,
          lastChunk: true,
        });
        this.#status(eventBus, taskId, contextId, TaskState.TASK_STATE_COMPLETED);
      } else if (text === 'ask') {
        this.#status(
          eventBus,
          taskId,
          contextId,
          TaskState.TASK_STATE_INPUT_REQUIRED,
          agentMessage(taskId, contextId, 'more?'),
        );
      } else if (text.startsWith('slow ')) {
        this.#status(eventBus, taskId, contextId, TaskState.TASK_STATE_WORKING);
        await sleep(Number(text.slice('slow '.length)));
        this.#artifact(eventBus, taskId, contextId, 'done');
        this.#status(eventBus, taskId, contextId, TaskState.TASK_STATE_COMPLETED);
      } else if (text === 'cancel-me') {
        this.#status(eventBus, taskId, contextId, TaskState.TASK_STATE_WORKING);
        while (!this.#cancelled.has(taskId)) {
          await sleep(50);
        }
        return;
      } else {
        this.#status(eventBus, taskId, contextId, TaskState.TASK_STATE_WORKING);
        this.#artifact(eventBus, taskId, contextId, `unknown: ${text}`);
        this.#status(eventBus, taskId, contextId, TaskState.TASK_STATE_COMPLETED);
      }
      eventBus.finished();
    } finally {
      this.#cancelled.delete(taskId);
      this.#contexts.delete(taskId);
    }
  }
}

function buildCard(port, binding) {
  const base = `http://127.0.0.1:${port}`;
  const interfaces = [];
  if (binding === 'jsonrpc' || binding === 'both') {
    interfaces.push({
      url: base + JSONRPC_PATH,
      protocolBinding: 'JSONRPC',
      tenant: '',
      protocolVersion: A2A_PROTOCOL_VERSION,
    });
  }
  if (binding === 'rest' || binding === 'both') {
    interfaces.push({
      url: base + REST_PREFIX,
      protocolBinding: 'HTTP+JSON',
      tenant: '',
      protocolVersion: A2A_PROTOCOL_VERSION,
    });
  }
  return {
    name: 'JS Test Agent',
    description: 'SDK agent mirroring barrel_a2a_test_agent',
    version: '1.2.3',
    supportedInterfaces: interfaces,
    provider: { organization: 'barrel_a2a interop', url: 'https://example.com' },
    capabilities: {
      streaming: true,
      pushNotifications: false,
      extensions: [],
      extendedAgentCard: false,
    },
    securitySchemes: {},
    securityRequirements: [],
    defaultInputModes: ['text/plain'],
    defaultOutputModes: ['text/plain'],
    skills: [
      {
        id: 'echo',
        name: 'Echo',
        description: 'Echoes text back',
        tags: ['test'],
        examples: [],
        inputModes: ['text/plain'],
        outputModes: ['text/plain'],
        securityRequirements: [],
      },
    ],
    documentationUrl: '',
    signatures: [],
  };
}

function main(argv) {
  const port = Number(argv[0]);
  const binding = argv[1] ?? 'both';
  if (!port || !['jsonrpc', 'rest', 'both'].includes(binding)) {
    process.stderr.write('usage: server.mjs <port> [jsonrpc|rest|both]\n');
    process.exit(2);
  }

  const card = buildCard(port, binding);
  const requestHandler = new DefaultRequestHandler(
    card,
    new InMemoryTaskStore(),
    new TestAgentExecutor(),
  );

  const app = express();
  app.use(`/${AGENT_CARD_PATH}`, agentCardHandler({ agentCardProvider: requestHandler }));
  if (binding === 'jsonrpc' || binding === 'both') {
    app.use(
      JSONRPC_PATH,
      jsonRpcHandler({ requestHandler, userBuilder: UserBuilder.noAuthentication }),
    );
  }
  if (binding === 'rest' || binding === 'both') {
    app.use(REST_PREFIX, restHandler({ requestHandler, userBuilder: UserBuilder.noAuthentication }));
  }

  app.listen(port, '127.0.0.1', () => {
    process.stdout.write(`READY ${port}\n`);
  });
}

main(process.argv.slice(2));
