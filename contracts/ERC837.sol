// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

abstract contract ERC837 is ERC20, ReentrancyGuard {
    using Counters for Counters.Counter;

    // ======================================================================== [ STORAGE ] ======================================================================== //

    // The struct handling the bets.
    struct Bet {
        address initializer; // The address that initializes the bet.
        string title; // The title of the bet.
        uint256 deadlineBlock; // The block that closes the bet.
        string[] options; // The available options to bet on.
        address[] walletsBets; // This array keeps track of all the wallets that bet.
        mapping(address => uint256) chosenBet; // This mapping keeps track of the option the wallet bet on.
        mapping(address => uint256) balanceBet; // This mapping keeps track of the bets balance placed by every wallet.
        uint256 balance; // The balance stored in the bet.
    }

    Counters.Counter public atBet; // @notice Counter that keeps track of the last bet.
    mapping(uint256 => Bet) public allBets; // @notice Mapping that stores all the bets.
    address public administrator; // @notice The administrator can change the default values.
    uint256 public MIN_DEADLINE_DURATION = 100; // @notice The minimum deadline value for the bets.
    uint256 public MAX_BET_OPTIONS = 3; // @notice The maximum amount of options available per bet.
    uint256 public CLOSING_FEE = 5; // @notice The fee kept by the contract in tokens on bet closing. (%)

    /// @notice The name of the token.
    string private _name;

    /// @notice The symbol of the token.
    string private _symbol;

    /**
     * @notice Event emitted when a new bet is created.
     * @param betId The returned ID of the bet.
     * @param initializer The address of the initializer.
     * @param title The title of the bet.
     * @param options The available options the users can bet on.
     * @param deadlineBlock The block number at which betting will end.
     */
    event BetCreated(uint256 indexed betId, address initializer, string title, string[] options, uint256 deadlineBlock);

    /**
     * @notice Event emitted when a bet is closed.
     * @param betId The ID of the bet.
     * @param initializer The address of the initializer that closes the bet.
     * @param winningOption The option that won the bet.
     */
    event BetClosed(uint256 indexed betId, address initializer, uint256 winningOption);

    
    /**
     * @notice Event emitted when a bet is placed by users.
     * @param betId The ID of the bet.
     * @param wallet The address of the user that places the bet.
     * @param option The user's betting option.
     */
    event BetPlaced(uint256 indexed betId, address wallet, uint256 option);

    /**
     * @notice Constructor to initialize the ERC837 token.
     * @param name_ The name of the ERC20 token.
     * @param symbol_ The symbol of the ERC20 token.
     */
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        administrator = msg.sender;
        _name = name_;
        _symbol = symbol_;
    }

    // ======================================================================== [ LOGIC ] ======================================================================== //

    /*
    @notice This function allows an user to create a bet.
    @param _title The title of the bet.
    @param _options A string array with all the available options to bet on.
    @param deadline The deadline block of the bet.
    */
    function createBet(string memory _title, string[] memory _options, uint256 deadline) payable external returns(uint256 id) {
        require(balanceOf(msg.sender) > 0, "ERC837: Only token holders can create bets.");
        require(deadline >= MIN_DEADLINE_DURATION, "ERC837: Deadline too short.");
        require(bytes(_title).length <= 50, "ERC837: Title cannot be longer than 50 characters.");
        require(_options.length >= 2 && _options.length <= MAX_BET_OPTIONS, "ERC837: Invalid amount of options.");

        id = atBet.current();

        uint256 deadlineBlock = block.number + deadline;


        allBets[id].initializer = msg.sender;
        allBets[id].title = _title;
        allBets[id].deadlineBlock = deadlineBlock;
        allBets[id].options = _options;
        allBets[id].balance = 0;

        atBet.increment();

        emit BetCreated(id, msg.sender, _title, _options, deadlineBlock);
    }

    /*
    @notice This function allows the initializer of the bet to close it.
    @param betId The id of the bet.
    @param option The winning option.
    */
    function closeBet(uint256 betId, uint256 option) external {
        Bet storage returnedBet = getBet(betId);
        require(returnedBet.initializer == msg.sender, "ERC837: Sender not initializer.");
        require(returnedBet.deadlineBlock >= block.number, "ERC837: This bet is still locked.");
        require(option >= 0 && option < returnedBet.options.length, "ERC837: Invalid option.");
        // getBalancePlacedOnOption
    }

    /*
    @notice This function allows the users to place a specific bet.
    @param betId The id of the bet.
    @param option The betting option.
    @param betBalance The amount of tokens to bet.
    */
    function placeBet(uint256 betId, uint256 option, uint betBalance) external {
        require(balanceOf(msg.sender) > 0, "ERC837: Only token holders can place bets.");

        Bet storage returnedBet = getBet(betId);
        require(!isBetPlacedByWallet(betId, msg.sender), "ERC837: Only 1 bet allowed per wallet.");
        require(option >= 0 && option < returnedBet.options.length, "ERC837: Invalid option for bet.");
        require(betBalance >= 0, "ERC837: Bet balance must be higher than 0.");
        require(balanceOf(msg.sender) >= betBalance, "ERC837: Not enough tokens to bet.");

        returnedBet.walletsBets.push(msg.sender);
        returnedBet.chosenBet[msg.sender] = option;
        returnedBet.balanceBet[msg.sender] = betBalance;
        super._transfer(msg.sender, address(this), betBalance);
    }

    // ======================================================================== [ GETTERS ] ======================================================================== //

    /*
    @notice This function is used internally to get the balance placed on a specific option.
    @param betId The id of the bet.
    @param option The option to check for.
    @return the balance bet on the specific option.
    */
    function getBalancePlacedOnOption(uint256 betId, uint256 option) private view returns(uint256 balance) {
        balance = 0;
        Bet storage returnedBet = getBet(betId);
        for(uint256 i = 0; i < returnedBet.walletsBets.length; i++) {
            address wallet = returnedBet.walletsBets[i];
            if(returnedBet.chosenBet[wallet] == option)
                balance += returnedBet.balanceBet[wallet];
        }
    }

    /*
    @notice This function is used internally to check if a wallet placed a bet on a specific id.
    @param betId The id of the bet.
    @return true if the wallet placed a bet on the specific id | false if the wallet didn't place a bet on the specific id.
    */
    function isBetPlacedByWallet(uint256 betId, address wallet) private view returns(bool) {
        Bet storage returnedBet = getBet(betId);
        for(uint256 i = 0; i < returnedBet.walletsBets.length; i++) {
            if(returnedBet.walletsBets[i] == wallet)
                return true;
        }
        return false;
    }

    /*
    @notice This function is used internally to retrieve a bet.
    @param betId The id of the bet.
    @return the bet at the specified id.
    */
    function getBet(uint256 betId) private view returns (Bet storage) {
        Bet storage returnedBet = allBets[betId];
        require(returnedBet.initializer != address(0), "ERC837: Bet does not exist.");
        return returnedBet;
    }

    /*
    @notice This function is used to retrieve the bet's initializer.
    @param betId The id of the bet.
    @return the address of the initializer.
    */
    function getBetInitializer(uint256 betId) public view returns (address) {
        return getBet(betId).initializer;
    }

    /*
    @notice This function is used to retrieve the bet's title.
    @param betId The id of the bet.
    @return the title.
    */
    function getBetTitle(uint256 betId) public view returns (string memory) {
        return getBet(betId).title;
    }

    /*
    @notice This function is used to retrieve the bet's deadline block.
    @param betId The id of the bet.
    @return the bet's deadline block.
    */
    function getBetDeadlineBlock(uint256 betId) public view returns (uint256) {
        return getBet(betId).deadlineBlock;
    }

    /*
    @notice This function is used to retrieve the bet's options.
    @param betId The id of the bet.
    @return the bet's options.
    */
    function getBetOptions(uint256 betId) public view returns (string[] memory) {
        return getBet(betId).options;
    }

    /*
    @notice This function is used to retrieve the bet's betters.
    @param betId The id of the bet.
    @return an array with all the betters of a specific bet.
    */
    function getBetters(uint256 betId) public view returns (address[] memory) {
        return getBet(betId).walletsBets;
    }

    /*
    @notice This function is used to retrieve the bet's options.
    @param betId The id of the bet.
    @return the options of a bet.
    */
    function getWalletBetOption(uint256 betId, address wallet) public view returns (uint256) {
        return getBet(betId).chosenBet[wallet];
    }

    /*
    @notice This function is used to retrieve the bet's pooled balance.
    @param betId The id of the bet.
    @return the pooled tokens in a bet.
    */
    function getBetPooledBalance(uint256 betId) public view returns (uint256) {
        return getBet(betId).balance;
    }

    // ======================================================================== [ SETTERS ] ======================================================================== //

    /*
    @notice This function is used by the administrator to change the minimum deadline duration.
    @param duration The new minimum deadline duration.
    */
    function setMinDeadlineDuration(uint256 duration) external {
        require(msg.sender == administrator, "ERC837: Not Administrator.");
        MIN_DEADLINE_DURATION = duration;
    }

    /*
    @notice This function is used by the administrator to change the maximum betting options.
    @param duration The new maximum betting options.
    */
    function setMaxBetOptions(uint256 options) external {
        require(msg.sender == administrator, "ERC837: Not Administrator.");
        MAX_BET_OPTIONS = options;
    }

    /*
    @notice This function is used by the administrator to change the administrator.
    @param admin The new administrator.
    */
    function setAdministrator(address admin) external {
        require(msg.sender == administrator, "ERC837: Not Administrator.");
        administrator = admin;
    }

    /*
    @notice This function is used by the administrator to change the closing fee.
    @param duration The new closing fee.
    */
    function setClosingFee(uint8 fee) external {
        require(msg.sender == administrator, "ERC837: Not Administrator.");
        require(fee >= 0 && fee <= 10, "ERC837: Invalid fee.");
        CLOSING_FEE = fee;
    }
}