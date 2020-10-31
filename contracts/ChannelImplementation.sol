// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.7.4;

import { ECDSA } from "@openzeppelin/contracts/cryptography/ECDSA.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { IERC20Token } from "./interfaces/IERC20Token.sol";
import { IHermesContract } from "./interfaces/IHermesContract.sol";
import { IUniswapV2Router } from "./interfaces/IUniswapV2Router.sol";
import { FundsRecovery } from "./FundsRecovery.sol";
import { Utils } from "./Utils.sol";

interface IdentityRegistry {
    function getBeneficiary(address _identity) external view returns (address);
    function setBeneficiary(address _identity, address _newBeneficiary, bytes memory _signature) external;
}

contract ChannelImplementation is FundsRecovery, Utils {
    using ECDSA for bytes32;
    using SafeMath for uint256;

    string constant EXIT_PREFIX = "Exit request:";
    uint256 constant DELAY_BLOCKS = 18000;  // +/- 4 days

    uint256 internal lastNonce;

    struct ExitRequest {
        uint256 timelock;          // block number after which exit can be finalized
        address beneficiary;       // address where funds will be send after finalizing exit request
    }

    struct Hermes {
        address operator;          // signing address
        address contractAddress;   // hermes smart contract address, funds will be send there
        uint256 settled;           // total amount already settled by hermes
    }

    ExitRequest public exitRequest;
    IdentityRegistry internal registry;
    Hermes public hermes;
    address public operator;          // channel operator = sha3(IdentityPublicKey)[:20]
    IUniswapV2Router internal dex;    // any uniswap v2 compatible dex router address

    event PromiseSettled(address beneficiary, uint256 amount, uint256 totalSettled);
    event ExitRequested(uint256 timelock);
    event Withdraw(address beneficiary, uint256 amount);

    /*
      ------------------------------------------- SETUP -------------------------------------------
    */

    // Fallback function - exchange received ETH into MYST
    receive() external payable {
        address[] memory path = new address[](2);
        path[0] = dex.WETH();
        path[1] = address(token);

        dex.swapExactETHForTokens{value: msg.value}(0, path, address(this), block.timestamp);
    }

    // Because of proxy pattern this function is used insted of constructor.
    // Have to be called right after proxy deployment.
    function initialize(address _token, address _dexAddress, address _identityHash, address _hermesId, uint256 _fee) public {
        require(!isInitialized(), "Is already initialized");
        require(_identityHash != address(0), "Identity can't be zero");
        require(_hermesId != address(0), "HermesID can't be zero");
        require(_token != address(0), "Token can't be deployd into zero address");

        token = IERC20Token(_token);
        dex = IUniswapV2Router(_dexAddress);

        // Transfer required fee to msg.sender (most probably Registry)
        if (_fee > 0) {
            token.transfer(msg.sender, _fee);
        }

        operator = _identityHash;
        transferOwnership(operator);
        hermes = Hermes(IHermesContract(_hermesId).getOperator(), _hermesId, 0);
    }

    function isInitialized() public view returns (bool) {
        return operator != address(0);
    }

    /*
      -------------------------------------- MAIN FUNCTIONALITY -----------------------------------
    */

    // Settle promise
    // signedMessage: channelId, totalSettleAmount, fee, hashlock
    // _lock is random number generated by receiver used in HTLC
    function settlePromise(uint256 _amount, uint256 _transactorFee, bytes32 _lock, bytes memory _signature) public {
        bytes32 _hashlock = keccak256(abi.encode(_lock));
        address _channelId = address(this);
        address _signer = keccak256(abi.encodePacked(getChainID(), uint256(_channelId), _amount, _transactorFee, _hashlock)).recover(_signature);
        require(_signer == operator, "have to be signed by channel operator");

        // Calculate amount of tokens to be claimed.
        uint256 _unpaidAmount = _amount.sub(hermes.settled);
        require(_unpaidAmount > 0, "amount to settle should be greater that already settled");

        // If signer has less tokens than asked to transfer, we can transfer as much as he has already
        // and rest tokens can be transferred via same promise but in another tx
        // when signer will top up channel balance.
        uint256 _currentBalance = token.balanceOf(_channelId);
        if (_unpaidAmount > _currentBalance) {
            _unpaidAmount = _currentBalance;
        }

        // Increase already paid amount
        hermes.settled = hermes.settled.add(_unpaidAmount);

        // Send tokens
        token.transfer(hermes.contractAddress, _unpaidAmount.sub(_transactorFee));

        // Pay fee to transaction maker
        if (_transactorFee > 0) {
            token.transfer(msg.sender, _transactorFee);
        }

        emit PromiseSettled(hermes.contractAddress, _unpaidAmount, hermes.settled);
    }

    // Returns blocknumber until which exit request should be locked
    function getTimelock() internal view virtual returns (uint256) {
        return block.number + DELAY_BLOCKS;
    }

    // Start withdrawal of deposited but still not settled funds
    // NOTE _validUntil is needed for replay protection
    function requestExit(address _beneficiary, uint256 _validUntil, bytes memory _signature) public {
        uint256 _timelock = getTimelock();

        require(exitRequest.timelock == 0, "Channel: new exit can be requested only when old one was finalised");
        require(_validUntil > block.number, "Channel: valid until have to be greater than current block number");
        require(_timelock > _validUntil, "Channel: request have to be valid shorter than DELAY_BLOCKS");
        require(_beneficiary != address(0), "Channel: beneficiary can't be zero address");

        if (msg.sender != operator) {
            address _channelId = address(this);
            address _signer = keccak256(abi.encodePacked(EXIT_PREFIX, _channelId, _beneficiary, _validUntil)).recover(_signature);
            require(_signer == operator, "Channel: have to be signed by operator");
        }

        exitRequest = ExitRequest(_timelock, _beneficiary);

        emit ExitRequested(_timelock);
    }

    // Anyone can finalize exit request after timelock block passed
    function finalizeExit() public {
        require(exitRequest.timelock != 0 && block.number >= exitRequest.timelock, "Channel: exit have to be requested and timelock have to be in past");

        // Exit with all not settled funds
        uint256 _amount = token.balanceOf(address(this));
        token.transfer(exitRequest.beneficiary, _amount);
        emit Withdraw(exitRequest.beneficiary, _amount);

        exitRequest = ExitRequest(0, address(0));  // deleting request
    }

    // Fast funds withdrawal is possible when hermes agrees that given amount of funds can be withdrawn
    function fastExit(uint256 _amount, uint256 _transactorFee, address _beneficiary, uint256 _validUntil, bytes memory _operatorSignature, bytes memory _hermesSignature) public {
        require(_validUntil >= block.number, "Channel: _validUntil have to be greater than or equal to current block number");

        address _channelId = address(this);
        bytes32 _msgHash = keccak256(abi.encodePacked(EXIT_PREFIX, getChainID(), uint256(_channelId), _amount, _transactorFee, uint256(_beneficiary), _validUntil, lastNonce++));

        address _firstSigner = _msgHash.recover(_operatorSignature);
        require(_firstSigner == operator, "Channel: have to be signed by operator");

        address _secondSigner = _msgHash.recover(_hermesSignature);
        require(_secondSigner == hermes.operator, "Channel: have to be signed by hermes");

        // Pay fee to transaction maker
        if (_transactorFee > 0) {
            require(_amount >= _transactorFee, "Channel: transactor fee can't be bigger that withdrawal amount");
            token.transfer(msg.sender, _transactorFee);
        }

        // Withdraw agreed amount
        uint256 _amountToSend = _amount.sub(_transactorFee);
        token.transfer(_beneficiary, _amountToSend);
        emit Withdraw(_beneficiary, _amountToSend);
    }
    /*
      ------------------------------------------ HELPERS ------------------------------------------
    */

    // Setting new destination of funds recovery.
    string constant FUNDS_DESTINATION_PREFIX = "Set funds destination:";
    function setFundsDestinationByCheque(address payable _newDestination, bytes memory _signature) public {
        require(_newDestination != address(0));

        address _channelId = address(this);
        address _signer = keccak256(abi.encodePacked(FUNDS_DESTINATION_PREFIX, _channelId, _newDestination, lastNonce++)).recover(_signature);
        require(_signer == operator, "Channel: have to be signed by proper identity");

        emit DestinationChanged(fundsDestination, _newDestination);

        fundsDestination = _newDestination;
    }

}
