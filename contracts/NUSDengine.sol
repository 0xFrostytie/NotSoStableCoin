//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NotSoStableCoin} from "./NotSoStableCoin.sol";

/**
 * @title NUSDengine
 * The engine that governs the NUSD stablecoin (lmeow)
 * @author Frosty
 * DO NOT
 * TRUST
 * THIS FUCKING ENGINE
 * I REPEAT
 * DO NOT WASTE YOUR DOLLARINOS ON THIS
 * 
 * The purpose is to get the coin pegged, I will not comment further on this topic. You make whatever you want from this sentence. Nuff said.
 * @notice This where it goes the fuck down. This is the reason you've literally wasted your dollarinos on a "stable" lmwo coin
 */


contract NUSDengine {
    error NUSDengine_needsMoreThanZero();
    error NUSDengine_AddressesGottaMatch();
    error NUSDengine__TokenNoAllowNo();
    error NUSDengine__TransferFailed();
    error NUSDEngine_BreaksHealthFactor(uint256 healthFactorValue);
    error NUSDEngine_MintFailed();
    error NUSDEngine_HealthFactorOk();
    error NUSDEngine_HealthFactorNotImproved();
 

    using OracleLib for AggregatorV3Interface;

    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_BONUS = 5; 
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;



    NotSoStableCoin private immutable i_nusd;


    mapping (address token => address priceFeed) private s_priceFeeds;

    mapping (address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    mapping(address user => uint256 amount) private s_NUSDminted;

    address[] private s_collateralTokens;




    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);


    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert NUSDengine_needsMoreThanZero();

        }

        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)){
            revert NUSDengine__TokenNoAllowNo(token);
        } 

        _;
    }


    constructor (
    address[] memory tokenAddresses, 
    address[] memory priceFeedAddresses,
    address nusdAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert NUSDengine_AddressesGottaMatch();
        }
        for (uint256 i=0; i < tokenAddresses.length; i++) {
            s_priceFeeds [tokenAddresses[i] = priceFeedAddresses[i]];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_nusd = NotSoStableCoin(nusdAddress);
    }


    function depositCollateralAndMintNUSD(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountNusdToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintNUSD(amountNusdToMint);
    }


    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert NUSDengine__TransferFailed();
        }
    }
    function redeemCollateralForNUSD(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountNusdToBurn)
        external
        moreThanZero(amountCollateral)
    {
        _burnNusd(amountNusdToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }


    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintNUSD(uint256 amountNUSDToMint) public moreThanZero(amountNUSDToMint) nonReentrant {
        s_NUSDminted[msg.sender] += amountNUSDToMint;

        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_nusd.mint(msg.sender, amountNUSDToMint);

        if (minted != true) {
            revert NUSDEngine_MintFailed();
        }
    }

    function burnNUSD(uint256 amount) external moreThanZero(amount) {
        _burnNUSD(amount, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
    }

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        _burnNUSD(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert NUSDEngine_HealthFactorNotImproved();
        }
        revertIfHealthFactorIsBroken(msg.sender);
    }


        function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert NUSDengine__TransferFailed();
        }
    }

    function _burnNUSD(uint256 amountNUSDToBurn, address onBehalfOf, address nusdFrom) private {
        s_NUSDMinted[onBehalfOf] -= amountNUSDToBurn;

        bool success = i_nusd.transferFrom(dscFrom, address(this), amountNUSDToBurn);
        // This conditional is hypothetically unreachable
        if (!success) {
            revert NUSDengine__TransferFailed();
        }
        i_nusd.burn(amountNUSDToBurn);
    }


    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalNUSDMinted, uint256 collateralValueInUsd)
    {
        totalNUSDMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalNUSDMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalNUSDMinted, collateralValueInUsd);
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(uint256 totalNUSDMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalNUSDMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalNUSDMinted;
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert NUSDEngine_BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////
    // External & Public View & Pure Functions
    ////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////
    function calculateHealthFactor(uint256 totalNUSDMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalNUSDMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalNUSDMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }



    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_nusd);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

}