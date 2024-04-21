import {
  GatewayInstance,
  OracleNodeInstance,
  PriceSet,
  configureCleanup,
  debug,
  setMockPricesMany,
  startAndWaitForGateway,
  startAndWaitForOracleNode,
  stopGateway,
  stopOracleNode,
  verifyPricesInCacheService,
  waitForDataAndDisplayIt,
} from "./framework/integration-test-framework";

const gatewayInstance1: GatewayInstance = { instanceId: "1" };
const oracleNodeInstance1: OracleNodeInstance = { instanceId: "1" };

const stopAll = () => {
  debug("stopAll called");
  stopOracleNode(oracleNodeInstance1);
  stopGateway(gatewayInstance1);
};

const main = async () => {
  setMockPricesMany({ __DEFAULT__: 42 }, [oracleNodeInstance1]);
  let expectedPrices: PriceSet = { BTC: 42 };

  await startAndWaitForGateway(gatewayInstance1, {
    directOnly: false,
    enableHistoricalDataServing: true,
  });
  await startAndWaitForOracleNode(
    oracleNodeInstance1,
    [gatewayInstance1],
    "single-source/mock",
    0,
    // non-routable address, generate price broadcasting timeout
    "http://10.255.255.1:91"
  );
  await waitForDataAndDisplayIt(gatewayInstance1);

  // verify prices being broadcast to working gateway
  await verifyPricesInCacheService([gatewayInstance1], expectedPrices);

  // verify prices are being updated in working gateway
  setMockPricesMany({ __DEFAULT__: 43 }, [oracleNodeInstance1]);
  expectedPrices = { BTC: 43 };
  await verifyPricesInCacheService([gatewayInstance1], expectedPrices);

  process.exit();
};

configureCleanup(stopAll);

void main();
