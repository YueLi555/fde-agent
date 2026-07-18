import { Principal, requireRole } from "./auth";

export interface OrderSummary {
  orderID: string;
  customerID: string;
  status: "processing" | "shipped";
}

const syntheticOrders: OrderSummary[] = [
  { orderID: "order-001", customerID: "customer-001", status: "processing" },
  { orderID: "order-002", customerID: "customer-002", status: "shipped" }
];

export function listCustomerOrders(principal: Principal, customerID: string): OrderSummary[] {
  requireRole(principal, "support");
  return syntheticOrders.filter((order) => order.customerID === customerID);
}
