This is a project to study pi.dev agents. The purpose is creating
multiple samples that allows to understand the potentiality of the
instrument and the various usage mode.

# layout

- notebooks: that folder contains notebook in typescript that will explore basic usage of PI as SDK
- samples: we have in this folder direct examples on how to use pi as a command-line agent. Each sample should contain a `README.md` that explains its purpose and how to run it.
  Samples should use PowerShell (`pwsh`) for executable scripts and commands.
  Shared PowerShell helpers belong in modules at the root of `samples/`.

Azure configuration is stored in a `.env` file with these exact variable names:

```text
AZURE_PI_TEST_ENDPOINT=<Azure OpenAI endpoint>
AZURE_PI_TEST_DEPLOYMENT=<Azure deployment name>
AZURE_PI_TEST_API_KEY=<API key for the deployment>
AZURE_PI_TEST_DEPLOYMENT2=<optional second deployment name>
```

Samples must use these `AZURE_PI_TEST_*` names. The hello-world PowerShell
sample registers a temporary OpenAI-compatible provider using
`AZURE_PI_TEST_ENDPOINT`, `AZURE_PI_TEST_DEPLOYMENT`, and
`AZURE_PI_TEST_API_KEY`; `AZURE_PI_TEST_DEPLOYMENT` is passed directly as the
model ID. `AZURE_PI_TEST_DEPLOYMENT2` is reserved for samples that need a
second deployment.

# rules

- Always try to run the sample before considering completed
- Do not overengineer the sample, keep it simple and focused on the purpose of the sample
- Add enought documentation to be instructive, the purpose is creating somethign that a developer uses to learn how to use pi.dev agents, it should have a teacher to student tone
