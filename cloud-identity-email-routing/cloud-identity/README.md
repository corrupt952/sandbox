# cloud-identity

The Google half. No code here and probably never any: it is all Admin console work, and what is worth keeping is what the console actually does.

Nothing here may name the real domain, account, or tenant. `example.com` and `agent@example.com` stand in for them.

## Creating an agent account

The account is a user on the secondary domain, created inside an organizational unit that has automatic licensing turned off. That toggle is the load-bearing detail: Google's own guidance is to keep "Switch off Auto-Assign" checked during Cloud Identity setup, and leaving it on hands every new user a paid Workspace license. Since policy cannot be applied per domain — "you can place users from each domain into separate organizational units" ([Limitations with multiple domains](https://knowledge.workspace.google.com/admin/domains/limitations-with-multiple-domains)) — an OU is where that setting has to live anyway, so agents get their own.

The recovery email field stays empty. It is where Google sends first-login instructions, and filling it in puts a mailbox back into an arrangement whose premise is not having one. Set the password by hand instead.

Local parts use a hyphen, not a dot. Gmail ignores dots in local parts and Cloudflare Email Routing does not, and the address is about to live on a domain routed to Cloudflare.

## Gotcha: the license banner is not an answer

The final screen of user creation displays "このユーザーには現在のサブスクリプションに基づいてライセンスが割り当てられます" — a license will be assigned based on your current subscription — even when the account is being created in an OU with automatic licensing off. Whether that is boilerplate or a real assignment is not something the screen settles. The billable user count under Billing settles it, so read that immediately before and after creating the account.
