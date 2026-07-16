import { Principal, requireRole } from "./auth";

export interface OrderSummary {
  orderID: string;
  customerID: string;
  status: "processing" | "shipped";
}

const syntheticOrders: OrderSummary[] = [
  { orderID: "<SYNTHETIC_ORDER_ID>", customerID: "<SYNTHETIC_CUSTOMER_ID>", status: "processing" }
];

export function listCustomerOrders(principal: Principal, customerID: string): OrderSummary[] {
  requireRole(principal, "support");
  return syntheticOrders.filter((order) => order.customerID === customerID);
}
