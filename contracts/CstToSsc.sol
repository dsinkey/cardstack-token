
import "./owned.sol";

contract CstToSsc is owned {
  uint public rewardPool;

  function buySSC(uint cstAmount) {
    // 1. convert CST to USD using CST buy price and ETH to USD oracle
    // 2. transfer CST to the owner of this contract
    // 3. increment rewardPool with the CST received
    // 4. issue SSC
  }
}