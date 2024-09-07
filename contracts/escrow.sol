// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 
import "@openzeppelin/contracts/security/ReentrancyGuard.sol"; 
import "@openzeppelin/contracts/access/Ownable.sol"; 

contract EnterpriseEscrow is ReentrancyGuard, Ownable {
    address public buyer;
    address public seller;
    address public escrowAgent;
    address public complianceAgent; // KYC or AML compliance agent
    uint public amount; // Escrow amount
    uint public deliveryDeadline;
    uint public escrowFee; // Fee in percentage, e.g., 1 = 1%
    bool public deliveryConfirmedBySeller = false;
    bool public kycPassed = false; // KYC compliance 
    
    
    
    IERC20 public token; // ERC20 token for multi-currency support 

    enum State { AWAITING_DELIVERY, DELIVERY_CONFIRMED, COMPLETE, REFUNDED }
    State public currentState;

    // Events for audit and tracking
    event DepositMade(address indexed buyer, uint amount);
    event FundsReleased(address indexed seller, uint amount);
    event RefundIssued(address indexed buyer, uint amount);
    event DeliveryConfirmed(address indexed seller);
    event StateChanged(State newState);
    event KYCCompleted(address indexed user, bool status);
    
    modifier onlyBuyer() {
        require(msg.sender == buyer, "Only the buyer can call this function");
        _;
    }

    modifier onlySeller() {
        require(msg.sender == seller, "Only the seller can call this function");
        _;
    }

    modifier onlyEscrowAgent() {
        require(msg.sender == escrowAgent, "Only the escrow agent can call this function");
        _;
    }

    modifier onlyComplianceAgent() {
        require(msg.sender == complianceAgent, "Only the compliance agent can call this function");
        _;
    }

    modifier inState(State _state) {
        require(currentState == _state, "Invalid state for this action");
        _;
    }

  
    constructor(
        address _buyer, 
        address _seller, 
        address _escrowAgent, 
        address _complianceAgent, 
        uint _escrowFee, 
        uint _deliveryTimeout, 
        uint _amount, 
        address _tokenAddress 
    ) Ownable(msg.sender) {  
        require(_amount > 0, "Escrow amount must be greater than 0");
        buyer = _buyer;
        seller = _seller;
        escrowAgent = _escrowAgent;
        complianceAgent = _complianceAgent;
        escrowFee = _escrowFee;
        deliveryDeadline = block.timestamp + _deliveryTimeout;
        amount = _amount;
        token = IERC20(_tokenAddress);
        currentState = State.AWAITING_DELIVERY;
        emit DepositMade(_buyer, _amount);
        emit StateChanged(currentState);
    }

    // KYC verification function called by the compliance agent
    function verifyKYC(bool _status) external onlyComplianceAgent {
        kycPassed = _status;
        emit KYCCompleted(buyer, _status);
    }

    // Deposit function (supports both ETH and ERC20 tokens)
    function deposit() external payable onlyBuyer inState(State.AWAITING_DELIVERY) nonReentrant {
        require(kycPassed, "KYC not completed"); // Ensure compliance before deposit
        if (address(token) == address(0)) {
            // If token address is zero, it's an ETH escrow
            require(msg.value == amount, "Incorrect ETH amount sent");
        } else {
            // Handle ERC20 token escrow
            require(token.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        }
        emit DepositMade(buyer, amount);
    }

    // Seller confirms delivery
    function confirmDelivery() external onlySeller inState(State.AWAITING_DELIVERY) nonReentrant {
        deliveryConfirmedBySeller = true;
        currentState = State.DELIVERY_CONFIRMED;
        emit DeliveryConfirmed(seller);
        emit StateChanged(currentState);
    }

    // Escrow agent releases funds to the seller
    function releaseFunds() external onlyEscrowAgent inState(State.DELIVERY_CONFIRMED) nonReentrant {
        uint fee = (amount * escrowFee) / 100; // Calculate escrow agent fee
        if (address(token) == address(0)) {
            // Handle ETH release
            payable(escrowAgent).transfer(fee); // Pay escrow agent
            payable(seller).transfer(amount - fee); // Transfer remaining amount to seller
        } else {
            // Handle ERC20 release
            require(token.transfer(escrowAgent, fee), "Escrow fee transfer failed");
            require(token.transfer(seller, amount - fee), "Seller transfer failed");
        }
        currentState = State.COMPLETE;
        emit FundsReleased(seller, amount - fee);
        emit StateChanged(currentState);
    }

    // Refund buyer if delivery not confirmed within deadline
    function refundBuyer() external onlyEscrowAgent nonReentrant {
        require(block.timestamp >= deliveryDeadline, "Deadline not reached");
        require(currentState == State.AWAITING_DELIVERY, "Cannot refund after delivery is confirmed");
        if (address(token) == address(0)) {
            payable(buyer).transfer(amount); // Refund ETH
        } else {
            require(token.transfer(buyer, amount), "Refund failed");
        }
        currentState = State.REFUNDED;
        emit RefundIssued(buyer, amount);
        emit StateChanged(currentState);
    }

    // Buyer can request refund after the deadline passes
    function refundAfterTimeout() external onlyBuyer nonReentrant {
        require(block.timestamp >= deliveryDeadline, "Deadline not reached");
        require(currentState == State.AWAITING_DELIVERY, "Cannot refund after delivery is confirmed");
        if (address(token) == address(0)) {
            payable(buyer).transfer(amount); // Refund ETH
        } else {
            require(token.transfer(buyer, amount), "Refund failed");
        }
        currentState = State.REFUNDED;
        emit RefundIssued(buyer, amount);
        emit StateChanged(currentState);
    }

    // Get the escrow fee
    function getEscrowFee() public view returns (uint) {
        return (amount * escrowFee) / 100;
    }

    // Get the remaining balance after escrow fee
    function getRemainingBalance() public view returns (uint) {
        return amount - getEscrowFee();
    }

    // Get contract's ETH or token balance (for debugging)
    function getContractBalance() public view returns (uint) {
        if (address(token) == address(0)) {
            return address(this).balance;
        } else {
            return token.balanceOf(address(this));
        }
    }
}
