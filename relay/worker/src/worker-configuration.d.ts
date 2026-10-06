import type { MachineRelay } from "./index";

declare global {
  interface Env {
    MACHINE_RELAY: DurableObjectNamespace<MachineRelay>;
    ALLOWED_ORIGINS?: string;
  }

  namespace Cloudflare {
    interface Env {
      MACHINE_RELAY: DurableObjectNamespace<MachineRelay>;
      ALLOWED_ORIGINS?: string;
    }
  }
}

export {};
