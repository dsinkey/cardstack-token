pragma solidity ^0.4.23;

import "zeppelin-solidity/contracts/ownership/Ownable.sol";
import "zeppelin-solidity/contracts/math/SafeMath.sol";
import "./ERC20.sol";
import "./freezable.sol";
import "./CstLedger.sol";
import "./ExternalStorage.sol";
import "./Registry.sol";
import "./CstLibrary.sol";
import "./displayable.sol";
import "./upgradeable.sol";
import "./configurable.sol";
import "./storable.sol";

contract CardStackToken is ERC20,
                           Ownable,
                           freezable,
                           displayable,
                           upgradeable,
                           configurable,
                           storable {

  using SafeMath for uint256;
  using CstLibrary for address;

  string public storageName;
  string public ledgerName;
  ITokenLedger public tokenLedger;
  address public externalStorage;
  address public registry;

  // These are mirrored in external storage so that state can live in future version of this contract
  // we save on gas prices by having these available as instance variables
  uint256 public buyPrice;
  uint256 public circulationCap;
  address public foundation;

  // Note that the data for the buyer whitelist itenationally lives in this contract
  // and not in storage, as this whitelist is specific to phase 1 token sale
  uint256 public cstBalanceLimit;
  uint256 public contributionMinimum;

  uint256 public totalCustomBuyersMapping;
  mapping (address => uint256) public customBuyerLimit;
  mapping (uint256 => address) public customBuyerForIndex;
  mapping (address => bool) processedCustomBuyer;

  uint256 public totalBuyersMapping;
  mapping (address => bool) public approvedBuyer;
  mapping (uint256 => address) public approvedBuyerForIndex;
  mapping (address => bool) processedBuyer;

  uint256 public totalTransferWhitelistMapping;
  mapping (address => bool) public whitelistedTransferer;
  mapping (uint256 => address) public whitelistedTransfererForIndex;
  mapping (address => bool) processedWhitelistedTransferer;

  uint256 public decimals = 0;
  bool public allowTransfers;

  event Mint(uint256 amountMinted, uint256 totalTokens, uint256 circulationCap);
  event Approval(address indexed _owner,
                 address indexed _spender,
                 uint256 _value);
  event Transfer(address indexed _from,
                 address indexed _to,
                 uint256 _value);
  event WhiteList(address indexed buyer, uint256 holdCap);
  event ConfigChanged(uint256 buyPrice, uint256 circulationCap, uint256 balanceLimit);
  event VestedTokenGrant(address indexed beneficiary, uint256 startDate, uint256 cliffDate, uint256 durationSec, uint256 fullyVestedAmount, bool isRevocable);
  event VestedTokenRevocation(address indexed beneficiary);
  event VestedTokenRelease(address indexed beneficiary, uint256 amount);
  event StorageUpdated(address storageAddress, address ledgerAddress);

  modifier onlyFoundation {
    if (msg.sender != owner && msg.sender != foundation) revert();
    _;
  }

  modifier initStorage {
    address ledgerAddress = Registry(registry).getStorage(ledgerName);
    address storageAddress = Registry(registry).getStorage(storageName);

    tokenLedger = ITokenLedger(ledgerAddress);
    externalStorage = storageAddress;
    _;
  }

  constructor(address _registry, string _storageName, string _ledgerName) public payable {
    require(_registry != address(0));
    storageName = _storageName;
    ledgerName = _ledgerName;
    registry = _registry;

    addSuperAdmin(registry);
  }

  /* This unnamed function is called whenever someone tries to send ether to it */
  function () public {
    revert();     // Prevents accidental sending of ether
  }

  function getLedgerNameHash() public view returns (bytes32) {
    return keccak256(ledgerName);
  }

  function getStorageNameHash() public view returns (bytes32) {
    return keccak256(storageName);
  }

  function configure(bytes32 _tokenName,
                     bytes32 _tokenSymbol,
                     uint256 _buyPrice,
                     uint256 _circulationCap,
                     uint256 _balanceLimit,
                     address _foundation) public onlySuperAdmins unlessUpgraded initStorage returns (bool) {

    if (buyPrice > 0 && buyPrice != _buyPrice) {
      require(frozenToken);
    }

    externalStorage.setTokenName(_tokenName);
    externalStorage.setTokenSymbol(_tokenSymbol);
    externalStorage.setBuyPrice(_buyPrice);
    externalStorage.setCirculationCap(_circulationCap);
    externalStorage.setFoundation(_foundation);

    // TODO refactor to use external storage exclusively for these vars
    buyPrice = _buyPrice;
    circulationCap = _circulationCap;
    foundation = _foundation;

    cstBalanceLimit = _balanceLimit;

    emit ConfigChanged(_buyPrice, _circulationCap, _balanceLimit);

    return true;
  }

  function configureFromStorage() public onlySuperAdmins unlessUpgraded initStorage returns (bool) {
    buyPrice = externalStorage.getBuyPrice();
    circulationCap = externalStorage.getCirculationCap();
    foundation = externalStorage.getFoundation();

    return true;
  }

  function updateStorage(string newStorageName, string newLedgerName) public onlySuperAdmins unlessUpgraded returns (bool) {
    storageName = newStorageName;
    ledgerName = newLedgerName;

    configureFromStorage();

    address ledgerAddress = Registry(registry).getStorage(ledgerName);
    address storageAddress = Registry(registry).getStorage(storageName);
    emit StorageUpdated(storageAddress, ledgerAddress);
    return true;
  }

  function name() public view unlessUpgraded returns(string) {
    return bytes32ToString(externalStorage.getTokenName());
  }

  function symbol() public view unlessUpgraded returns(string) {
    return bytes32ToString(externalStorage.getTokenSymbol());
  }

  function totalInCirculation() public view unlessUpgraded returns(uint256) {
    return tokenLedger.totalInCirculation().add(totalUnvestedAndUnreleasedTokens());
  }

  function totalSupply() public view unlessUpgraded returns(uint256) {
    return tokenLedger.totalTokens();
  }

  function tokensAvailable() public view unlessUpgraded returns(uint256) {
    return totalSupply().sub(totalInCirculation());
  }

  function balanceOf(address account) public view unlessUpgraded returns (uint256) {
    address thisAddress = this;
    if (thisAddress == account) {
      return tokensAvailable();
    } else {
      return tokenLedger.balanceOf(account);
    }
  }

  function transfer(address recipient, uint256 amount) public unlessFrozen unlessUpgraded returns (bool) {
    require(allowTransfers || whitelistedTransferer[msg.sender]);
    require(amount > 0);
    require(!frozenAccount[recipient]);

    tokenLedger.transfer(msg.sender, recipient, amount);
    emit Transfer(msg.sender, recipient, amount);

    return true;
  }

  function mintTokens(uint256 mintedAmount) public onlySuperAdmins unlessFrozen unlessUpgraded returns (bool) {
    tokenLedger.mintTokens(mintedAmount);

    emit Mint(mintedAmount, tokenLedger.totalTokens(), circulationCap);

    emit Transfer(address(0), this, mintedAmount);

    return true;
  }

  function grantTokens(address recipient, uint256 amount) public onlySuperAdmins unlessFrozen unlessUpgraded returns (bool) {
    require(amount <= tokensAvailable());
    require(!frozenAccount[recipient]);

    tokenLedger.debitAccount(recipient, amount);
    emit Transfer(this, recipient, amount);

    return true;
  }

  function buy() public payable unlessFrozen unlessUpgraded returns (uint256) {
    require(msg.value >= buyPrice);
    require(approvedBuyer[msg.sender]);
    require(buyPrice > 0);
    require(circulationCap > 0);

    uint256 amount = msg.value.div(buyPrice);
    require(totalInCirculation().add(amount) <= circulationCap);
    require(amount <= tokensAvailable());

    uint256 balanceLimit;
    uint256 buyerBalance = tokenLedger.balanceOf(msg.sender);
    uint256 customLimit = customBuyerLimit[msg.sender];
    require(contributionMinimum == 0 || buyerBalance.add(amount) >= contributionMinimum);

    if (customLimit > 0) {
      balanceLimit = customLimit;
    } else {
      balanceLimit = cstBalanceLimit;
    }

    require(balanceLimit > 0 && balanceLimit >= buyerBalance.add(amount));

    tokenLedger.debitAccount(msg.sender, amount);
    emit Transfer(this, msg.sender, amount);

    return amount;
  }

  function foundationWithdraw(uint256 amount) public onlyFoundation returns (bool) {
    /* UNTRUSTED */
    msg.sender.transfer(amount);

    return true;
  }

  // intentionally did not lock this down to foundation only. if someone wants to send ethers, no biggie0:w
  function foundationDeposit() public payable unlessUpgraded returns (bool) {
    return true;
  }

  function allowance(address owner, address spender) public view unlessUpgraded returns (uint256) {
    return externalStorage.getAllowance(owner, spender);
  }

  function transferFrom(address from, address to, uint256 value) public unlessFrozen unlessUpgraded returns (bool) {
    require(allowTransfers);
    require(!frozenAccount[from]);
    require(!frozenAccount[to]);
    require(from != msg.sender);
    require(value > 0);

    uint256 allowanceValue = allowance(from, msg.sender);
    require(allowanceValue >= value);

    tokenLedger.transfer(from, to, value);
    externalStorage.setAllowance(from, msg.sender, allowanceValue.sub(value));

    emit Transfer(from, to, value);
    return true;
  }

  /* Beware that changing an allowance with this method brings the risk that someone may use both the old
   * and the new allowance by unfortunate transaction ordering. One possible solution to mitigate this
   * race condition is to first reduce the spender's allowance to 0 and set the desired value afterwards:
   * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
   *
   * Please use `increaseApproval` or `decreaseApproval` instead.
   */
  function approve(address spender, uint256 value) public unlessFrozen unlessUpgraded returns (bool) {
    require(spender != address(0));
    require(!frozenAccount[spender]);
    require(msg.sender != spender);

    externalStorage.setAllowance(msg.sender, spender, value);

    emit Approval(msg.sender, spender, value);
    return true;
  }

  function increaseApproval(address spender, uint256 addedValue) public unlessFrozen unlessUpgraded returns (bool) {
    return approve(spender, externalStorage.getAllowance(msg.sender, spender).add(addedValue));
  }

  function decreaseApproval(address spender, uint256 subtractedValue) public unlessFrozen unlessUpgraded returns (bool) {
    uint256 oldValue = externalStorage.getAllowance(msg.sender, spender);

    if (subtractedValue > oldValue) {
      return approve(spender, 0);
    } else {
      return approve(spender, oldValue.sub(subtractedValue));
    }
  }

  function grantVestedTokens(address beneficiary,
                             uint256 fullyVestedAmount,
                             uint256 startDate, // 0 indicates start "now"
                             uint256 cliffSec,
                             uint256 durationSec,
                             bool isRevocable) public onlySuperAdmins unlessUpgraded unlessFrozen returns(bool) {

    require(beneficiary != address(0));
    require(!frozenAccount[beneficiary]);
    require(durationSec >= cliffSec);
    require(totalInCirculation().add(fullyVestedAmount) <= circulationCap);
    require(fullyVestedAmount <= tokensAvailable());

    uint256 _now = now;
    if (startDate == 0) {
      startDate = _now;
    }

    uint256 cliffDate = startDate.add(cliffSec);

    externalStorage.setVestingSchedule(beneficiary,
                                       fullyVestedAmount,
                                       startDate,
                                       cliffDate,
                                       durationSec,
                                       isRevocable);

    emit VestedTokenGrant(beneficiary, startDate, cliffDate, durationSec, fullyVestedAmount, isRevocable);

    return true;
  }


  function revokeVesting(address beneficiary) public onlySuperAdmins unlessUpgraded unlessFrozen returns (bool) {
    require(beneficiary != address(0));
    externalStorage.revokeVesting(beneficiary);

    releaseVestedTokensForBeneficiary(beneficiary);

    emit VestedTokenRevocation(beneficiary);

    return true;
  }

  function releaseVestedTokens() public unlessFrozen unlessUpgraded returns (bool) {
    return releaseVestedTokensForBeneficiary(msg.sender);
  }

  function releaseVestedTokensForBeneficiary(address beneficiary) public unlessFrozen unlessUpgraded returns (bool) {
    require(beneficiary != address(0));
    require(!frozenAccount[beneficiary]);

    uint256 unreleased = releasableAmount(beneficiary);

    if (unreleased == 0) { return true; }

    externalStorage.releaseVestedTokens(beneficiary);

    tokenLedger.debitAccount(beneficiary, unreleased);
    emit Transfer(this, beneficiary, unreleased);

    emit VestedTokenRelease(beneficiary, unreleased);

    return true;
  }

  function releasableAmount(address beneficiary) public view unlessUpgraded returns (uint256) {
    return externalStorage.releasableAmount(beneficiary);
  }

  function totalUnvestedAndUnreleasedTokens() public view unlessUpgraded returns (uint256) {
    return externalStorage.getTotalUnvestedAndUnreleasedTokens();
  }

  function vestingMappingSize() public view unlessUpgraded returns (uint256) {
    return externalStorage.vestingMappingSize();
  }

  function vestingBeneficiaryForIndex(uint256 index) public view unlessUpgraded returns (address) {
    return externalStorage.vestingBeneficiaryForIndex(index);
  }

  function vestingSchedule(address _beneficiary) public
                                                 view unlessUpgraded returns (uint256 startDate,
                                                                              uint256 cliffDate,
                                                                              uint256 durationSec,
                                                                              uint256 fullyVestedAmount,
                                                                              uint256 vestedAmount,
                                                                              uint256 vestedAvailableAmount,
                                                                              uint256 releasedAmount,
                                                                              uint256 revokeDate,
                                                                              bool isRevocable) {
    (
      startDate,
      cliffDate,
      durationSec,
      fullyVestedAmount,
      releasedAmount,
      revokeDate,
      isRevocable
    ) =  externalStorage.getVestingSchedule(_beneficiary);

    vestedAmount = externalStorage.vestedAmount(_beneficiary);
    vestedAvailableAmount = externalStorage.vestedAvailableAmount(_beneficiary);
  }

  function setCustomBuyer(address buyer, uint256 balanceLimit) public onlySuperAdmins unlessUpgraded returns (bool) {
    require(buyer != address(0));
    customBuyerLimit[buyer] = balanceLimit;
    if (!processedCustomBuyer[buyer]) {
      processedCustomBuyer[buyer] = true;
      customBuyerForIndex[totalCustomBuyersMapping] = buyer;
      totalCustomBuyersMapping = totalCustomBuyersMapping.add(1);
    }
    addBuyer(buyer);

    return true;
  }

  function setAllowTransfers(bool _allowTransfers) public onlySuperAdmins unlessUpgraded returns (bool) {
    allowTransfers = _allowTransfers;
    return true;
  }

  function setContributionMinimum(uint256 _contributionMinimum) public onlySuperAdmins unlessUpgraded returns (bool) {
    contributionMinimum = _contributionMinimum;
    return true;
  }

  function addBuyer(address buyer) public onlySuperAdmins unlessUpgraded returns (bool) {
    require(buyer != address(0));
    approvedBuyer[buyer] = true;
    if (!processedBuyer[buyer]) {
      processedBuyer[buyer] = true;
      approvedBuyerForIndex[totalBuyersMapping] = buyer;
      totalBuyersMapping = totalBuyersMapping.add(1);
    }

    uint256 balanceLimit = customBuyerLimit[buyer];
    if (balanceLimit == 0) {
      balanceLimit = cstBalanceLimit;
    }

    emit WhiteList(buyer, balanceLimit);

    return true;
  }

  function removeBuyer(address buyer) public onlySuperAdmins unlessUpgraded returns (bool) {
    require(buyer != address(0));
    approvedBuyer[buyer] = false;

    return true;
  }

  function setWhitelistedTransferer(address transferer, bool _allowTransfers) public onlySuperAdmins unlessUpgraded returns (bool) {
    require(transferer != address(0));
    whitelistedTransferer[transferer] = _allowTransfers;
    if (!processedWhitelistedTransferer[transferer]) {
      processedWhitelistedTransferer[transferer] = true;
      whitelistedTransfererForIndex[totalTransferWhitelistMapping] = transferer;
      totalTransferWhitelistMapping = totalTransferWhitelistMapping.add(1);
    }

    return true;
  }
}
