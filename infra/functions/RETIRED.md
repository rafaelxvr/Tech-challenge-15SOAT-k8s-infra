# Retired legacy Functions roots

`infra/functions/{staging,production}` and `infra/modules/functions` are retained as historical migration references only. They are no longer an owner of Lambda, API Gateway, SQS, DynamoDB, IAM or logging resources.

The authoritative owner is `oficina-functions/infra/environments/{staging,production}`. The legacy environment roots contain an unconditional Terraform precondition that fails before any resource can be planned or applied. Do not delete or import legacy state from this repository; perform any state migration only through the reviewed FUN ownership handoff.
