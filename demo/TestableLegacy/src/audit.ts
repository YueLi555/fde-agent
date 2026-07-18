export interface AuditRecord {
  actorID: string;
  action: "orders.read";
  resourceID: string;
  outcome: "allowed" | "denied";
}

export function recordAuditEvent(record: AuditRecord): string {
  return JSON.stringify(record);
}
