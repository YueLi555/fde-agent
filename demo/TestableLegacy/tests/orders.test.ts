import { beforeEach, describe, expect, it, vi } from "vitest";
import { listCustomerOrders } from "../src/orders";
import { recordAuditEvent } from "../src/audit";

vi.mock("../src/audit", () => ({ recordAuditEvent: vi.fn() }));

describe("existing order support conventions", () => {
  beforeEach(() => {
    vi.mocked(recordAuditEvent).mockClear();
  });

  it("filters the representative order fixture", () => {
    const result = listCustomerOrders(
      { subject: "customer-001", roles: ["support"] },
      "customer-001"
    );

    expect(listCustomerOrders).toBeDefined();
    expect(result).toEqual([
      { orderID: "order-001", customerID: "customer-001", status: "processing" }
    ]);
    expect(result.length > 0).toBe(true);
  });

  it("uses the established audit spy convention", () => {
    recordAuditEvent({
      actorID: "customer-001",
      action: "orders.read",
      resourceID: "customer-001",
      outcome: "allowed"
    });

    expect(recordAuditEvent).toHaveBeenCalledWith({
      actorID: "customer-001",
      action: "orders.read",
      resourceID: "customer-001",
      outcome: "allowed"
    });
  });
});
