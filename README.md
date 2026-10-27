# Rearc quest on AWS

This is my solution to Rearc's quest: the quest app running in a container on AWS Fargate, behind a load balancer with TLS, with all of the infrastructure in Terraform. It's live at https://rearcquest.com and will stay up until after my interview. The original instructions are at https://github.com/rearc/quest.

## Contents

- [Two Fargate tasks run behind an ALB in two zones](#two-fargate-tasks-run-behind-an-alb-in-two-zones)
- [Four checks pass, and /docker can't on Fargate](#four-checks-pass-and-docker-cant-on-fargate)
- [The shell is gone and the app holds no AWS credentials](#the-shell-is-gone-and-the-app-holds-no-aws-credentials)
- [Terraform plans deploy everything except the secret word](#terraform-plans-deploy-everything-except-the-secret-word)
- [Teardown needs care in three places](#teardown-needs-care-in-three-places)
- [Given more time, I would improve...](#given-more-time-i-would-improve)
- [Claude wrote the infrastructure code, and I made every decision](#claude-wrote-the-infrastructure-code-and-i-made-every-decision)

## Two Fargate tasks run behind an ALB in two zones

```
Internet → Route 53 (rearcquest.com) → ALB, HTTPS (public subnets, us-east-2a and 2b)
         → 2 Fargate tasks (private subnets, no public IP)
         → 1 NAT gateway → ECR, SSM Parameter Store, CloudWatch Logs
```

- **Network** – A VPC (`10.0.0.0/16`) across two Availability Zones (AZs), with private and public subnets in each and one NAT gateway. The ALB needs subnets in at least two AZs, and two tasks in two zones keep the app up if one zone fails.
- **Load balancer** – An internet-facing Application Load Balancer (ALB) serves HTTPS on 443 and redirects HTTP on 80 to HTTPS with a 301. Its health check targets `/docker`, which answers from inside the container; `/` would fetch www.rearc.io on every probe.
- **DNS and TLS** – `rearcquest.com` is registered at DNSimple and delegated to a Route 53 zone. The certificate is from ACM, DNS-validated, for `rearcquest.com` and `www.rearcquest.com`.
- **Compute** – An ECS service on Fargate runs two tasks (0.25 vCPU, 512 MB, `X86_64`) in the private subnets. Fargate means no servers to patch, and EKS would add a control plane's cost and complexity for one container.
- **Images** – The `quest` ECR repository has immutable tags, scans on push and keeps the 10 newest images. GitHub Actions builds the image ([`.github/workflows/build.yml`](.github/workflows/build.yml)) and pushes it as `quest:<git sha>`, logging in to AWS through OIDC.
- **Terraform** – Everything in [`infrastructure/`](infrastructure/) runs in Terraform Cloud (workspace `quest`), which logs in to AWS through OIDC. No long-lived AWS keys exist anywhere, in GitHub or in Terraform Cloud.
- **Small extras** – An S3 gateway endpoint keeps ECR image-layer pulls off the NAT gateway's data charge, and it's free. A $100 monthly AWS Budget sends email alerts at $40 and $50 of actual spend and at $100 forecast. VPC flow logs and Route 53 Resolver query logs (7 days each) record what the binaries connect to and look up, because I can't read their source. They recorded 1,883 DNS lookups: 1,755 for `metadata.google.internal` (the binaries probing for GCP), 73 for `www.rearc.io`, and the rest for AWS service endpoints (ECR, S3, SSM, CloudWatch Logs).

## Four checks pass, and /docker can't on Fargate

I checked each route with `curl` and took a screenshot of each in Chrome.

| Check | Result | Screenshot |
|---|---|---|
| `/` | `NostraCulpa`, the secret word | [index.png](docs/screenshots/index.png) |
| `/secret_word` | "Congratulations. Secret word is: NostraCulpa" | [secret_word.png](docs/screenshots/secret_word.png) |
| `/loadbalanced` | "Congratulations! Looks like you successfully configured an AWS loadbalancer" | [loadbalanced.png](docs/screenshots/loadbalanced.png) |
| `/tls` | "Congratulations! Looks like you successfully configured TLS (https)" | [tls.png](docs/screenshots/tls.png) |
| `/docker` | "You dont seem to be running in a Docker container. This might be OK as many cloud container orchestration platforms do not use Docker" | [docker.png](docs/screenshots/docker.png) |

`/aws` also returns "Congratulations! You are running in AWS, Detected: ECS,AWS".

- **`/docker`** – Fargate runs containers on containerd, not Docker, so this answer is correct. I could turn it green by adding a fake Docker marker file to the image, but that would make the check report something untrue, so I left it.
- **`/secret_word`** – This route echoes whatever `SECRET_WORD` is set to (it said "placeholder" before I set the real value), so it doesn't validate the word. The word is right because it's the same text https://www.rearc.io/quest001001222 serves.

## The shell is gone and the app holds no AWS credentials

- **Shell injection** – In the original app, `/loadbalanced`, `/tls` and `/secret_word` passed the request headers to the binaries through `child_process.exec`, which runs a shell, so a header like `X-A: $(id)` ran a command in the container. I reported it to Rearc, and Rearc's PR [rearc/quest#61](https://github.com/rearc/quest/pull/61) (by Alexander Dupuy) replaces `exec` with `execFile` on all six routes. It was merged upstream on 2026-10-27. I took Rearc's version over my own fix and applied the identical diff here as `abcee9a` before building anything, so the app's code matches Rearc's current `master`.
- **No task role** – The binaries query cloud metadata endpoints to detect where they run. The ECS task has no task role, meaning that anything that makes the app query the task metadata endpoint finds no credentials. The execution role, which only the ECS agent uses, can pull from the one ECR repository, write to its own log group and read the one parameter. The parameter uses the AWS-managed `aws/ssm` key, whose key policy already allows decryption through SSM, so the role needs no KMS statement.
- **Read-only plans** – A Terraform plan runs code from the repo, and this repo is a public fork. So the plan phase gets a read-only role, and the admin role is used only by the apply phase, which runs after I confirm the plan. Speculative plans are off.
- **Non-root container** – The container runs as the `node` user, and the app's files are root-owned and not writable by it.
- **The secret word stays out of git** – `SECRET_WORD` is an SSM Parameter Store SecureString that ECS injects at start. Terraform creates it as `placeholder` and ignores its value afterward, meaning that Terraform never sets the real word, so it isn't in git. The real value lives in Parameter Store, and Terraform Cloud reads it back into state on refresh. The word is public on the index page anyway.
- **The load balancer** – TLS 1.2 and 1.3 only (`ELBSecurityPolicy-TLS13-1-2-2021-06`), invalid header fields dropped, and the tasks accept traffic only from the ALB's security group.
- **The image build** – The GitHub push role trusts only the `master` branch of this repo, through GitHub's immutable subject claim, and can push only to the one repository. Every action in the workflow is pinned to a commit SHA, and GitHub holds no AWS secrets.
- **A separate AWS account** – The quest runs in its own account, reached through SSO, so nothing else I run is inside its blast radius.

## Terraform plans deploy everything except the secret word

**Infrastructure changes.** A push to `master` that changes anything under `infrastructure/` queues a plan on the `quest` workspace. I review it and confirm the apply. Nothing applies on its own.

**App changes.** A push to `master` that touches the `Dockerfile`, `src/`, `bin/`, `package*.json` or the workflow builds a `linux/amd64` image and pushes `quest:<git sha>` to ECR. To deploy it:

1. Set the Terraform variable `image_tag` on the workspace to the full 40-character SHA.
2. Queue a run and review the plan. It should replace the task definition with a new revision and update the service.
3. Confirm the apply. ECS rolls both tasks, and a deployment circuit breaker rolls back if the new ones fail to start or fail the ALB health check (`/docker`).

**Setting the secret word.** Tasks read secrets only when they start, so set the parameter and then redeploy:

```
aws ssm put-parameter --name /quest/secret_word --value <word> --overwrite
aws ecs update-service --cluster quest --service quest --force-new-deployment
```

**One-time setup, already done here.**

- **The Terraform Cloud login** – The OIDC provider and the two roles Terraform Cloud logs in with can't create themselves, so I created them once by hand and adopted them into state with `import` blocks ([`infrastructure/tfc-oidc.tf`](infrastructure/tfc-oidc.tf)).
- **Workspace variables** – Environment variables `TFC_AWS_PROVIDER_AUTH=true`, `TFC_AWS_PLAN_ROLE_ARN` and `TFC_AWS_APPLY_ROLE_ARN`, and Terraform variables `image_tag` and `budget_alert_email` (the email is kept on the workspace because the repo is public).
- **The domain delegation** – The registrar's name servers point at the Route 53 zone (output `route53_name_servers`). The certificate can't validate until they do, and the apply waits up to 45 minutes for it.
- **Build order** – The service needs an image to run, so I built ECR and the push role first, then the image, then ECS and the ALB.

## Teardown needs care in three places

I haven't torn it down yet. I'll do it after my interview by queuing a destroy run on the `quest` workspace and confirming it. Three things don't come down cleanly on their own:

- **The ECR repository** – It has to be empty, or force-deleted, before Terraform can delete it.
- **Terraform Cloud's own login** – The OIDC provider and the two Terraform Cloud roles are in state, so the destroy deletes them too. To keep the run from deleting its own credentials, I'll first add `removed { lifecycle { destroy = false } }` blocks for the provider, the two roles and their two policy attachments, and apply, so Terraform forgets them without deleting them. Then I'll run the destroy, and delete those five by hand afterward.
- **The delegation** – The name servers at DNSimple are outside Terraform, so I'll point them away from the deleted zone by hand.

## Given more time, I would improve...

I kept the app's code as Rearc wrote it, apart from the shell-injection fix, the same way I'd treat an app I don't own. Most of these are in that code.

- **Express `~4.16.3`** – It resolves to 4.16.4, whose `qs` has CVE-2022-24999, prototype poisoning that can hang the process. It's reachable, because Express parses the query string on every request. Express 4.17.3 fixes it. I didn't bump it, so the app code stays identical to Rearc's current `master`.
- **Errors** – Five routes return an empty 200 when their binary fails, and `/` returns the binary's raw stderr, which leaks host details. I'd log stderr and return a 500. The app also finds `bin/` relative to the working directory and hardcodes port 3000.
- **The binaries** – They're amd64-only, so the image can't run on Graviton. They're unsigned and built from source that isn't public, so I can't verify or rebuild them. And with #61 they get one `key:value` argument per header; the checks pass that way, but I haven't tested a header name starting with `-`, which a binary could read as a flag.
- **Base image CVEs** – ECR's scan of the deployed image found 7 HIGH, 2 MEDIUM and 2 LOW findings, all in Debian packages of `node:22-slim` (util-linux, zlib, glibc) and none in the app. I'd rebuild on a patched base and look at a distroless or Chainguard image.
- **Deploys** – Setting `image_tag` by hand is a manual step. I'd have the build update it, once I decide where the human review belongs.
- **One NAT gateway** – I chose one instead of one per AZ to save about $33 a month before data charges. If its zone fails, the running tasks keep serving, but new tasks can't pull images or read the secret, so they can't start. In production I'd run one per AZ.
- **Production basics** – There's no WAF, ALB access logs are off, there's no autoscaling and the root filesystem isn't read-only.

## Claude wrote the infrastructure code, and I made every decision

I used Claude Code throughout. I asked Claude for a read-only review of the quest before I built anything, looking for backdoors and security issues. It read the code through the GitHub API and inspected the six binaries with static tools only, never running them. It found no backdoor, but found the shell injection. A second, independent review, whose brief didn't mention security, found the same injection on its own.

After that, Claude planned each step with me, wrote the Terraform, the Dockerfile and the workflow, and ran the checks. It also drafted this README from my build notes. Claude showed me each plan's resource list, and I approved every Terraform apply and every AWS change.

**Some of my prompts, verbatim:**

- "Let's pick up the Rearc Quest. What remains?"
- "Start and build them."
- "We're going to use Parameter Store for the secret word."
- "Go ahead and apply the fix."

**What it got wrong:**

- **One admin role for every run phase** – Claude's first version of the Terraform Cloud login gave plans admin credentials. An automated security review caught it, and I split the roles.
- **The GitHub OIDC subject** – The push role trusted `repo:sarah-savage/quest:ref:refs/heads/master`, but this repo sends GitHub's immutable subject (`repo:sarah-savage@112581092/quest@1435536201:…`), so the first image build was refused. The failed run's log showed it, and it was a one-line fix (`784d12e`).
- **No CA certificates** – `node:22-slim` has none, and the image was never run end to end before it was deployed (the binaries hadn't been sandboxed, so they weren't run locally), so the index page first served a Go panic, `x509: certificate signed by unknown authority`. Installing `ca-certificates` fixed it (`6d7ddb1`). That's also how I saw the stderr leak on `/` in production.
- **Smaller misses** – A shell quoting error in the first IAM bootstrap attempt (before it created anything), and an assumption that a push would start a Terraform Cloud run before Terraform Cloud's GitHub App had access to the repo.
