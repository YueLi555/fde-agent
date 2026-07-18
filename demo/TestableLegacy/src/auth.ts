export type Role = "support" | "auditor";

export interface Principal {
  subject: string;
  roles: Role[];
}

export function authenticate(exampleToken: string | undefined): Principal {
  if (!exampleToken) {
    throw new Error("authentication required");
  }
  return { subject: "customer-001", roles: ["support"] };
}

export function requireRole(principal: Principal, role: Role): void {
  if (!principal.roles.includes(role)) {
    throw new Error("forbidden");
  }
}
