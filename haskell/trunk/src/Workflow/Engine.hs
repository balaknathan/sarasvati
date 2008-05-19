-- Author: Paul Lorenz

module Workflow.Engine where
import qualified Data.Map as Map
import qualified Workflow.Util.ListUtil as ListUtil
import Data.Dynamic
import Control.Monad

-- GuardResponse
--   Nodes have guard functions which determine if the accept function when a token
--   arrives and the node is ready to be activated. Guard functions must return a
--   GuardResponse
--
--   AcceptToken  - The token is passed on to the accept function
--   DiscardToken - The token is discarded and the accept function is not called
--   SkipNode     - The accept function is not called. The token is not discarded,
--                  the completeExecution function is called instead.

data GuardResponse = AcceptToken | DiscardToken | SkipNode String
  deriving (Show)

data NodeSource =
    NodeSource {
        wfName     :: String,
        wfVersion  :: String,
        wfInstance :: String,
        wfDepth    :: Int
    }
 deriving (Show, Eq)


-- NodeExtra is a place to store any extra data that a given node may
-- require. The only requirement is that the 'extra data' be a Typeable
-- so it can encapsulated in a Dynamic

data NodeExtra = NoNodeExtra | NodeExtra Dynamic

makeNodeExtra :: (Typeable a) => a -> NodeExtra
makeNodeExtra extra = NodeExtra $ toDyn extra

instance Show (NodeExtra) where
    show NoNodeExtra = "NoNodeExtra"
    show _           = "NodeExtra: Dynamic"


-- Node
--   Represents a node in a workflow graph.
--
--   Members:
--     nodeId - An integer id, which should be unique. Used for testing equality
--     accept - function which handles incoming tokens.
--
--   Connections between Nodes are represented by Arcs and WFGraph

data Node =
    Node {
        nodeId       :: Int,
        nodeType     :: String,
        nodeName     :: String,
        nodeSource   :: NodeSource,
        nodeIsJoin   :: Bool,
        nodeExtra    :: NodeExtra
    }

instance Show (Node) where
    show a = "|Node id: " ++ (show.nodeId) a ++ " name: " ++ nodeName a ++
             " depth: " ++ (show.nodeSource) a ++ "|"

-- NodeType
--   Encapsulates node functionality

data NodeType a =
    NodeType {
        guardFunction  :: (NodeToken -> WfProcess a -> GuardResponse),
        acceptFunction :: (WfEngine engine) => (engine -> NodeToken -> WfProcess a -> IO (WfProcess a))
    }


-- Arc
--   An Arc represents an directed edge in a workflow graph.
--   It has an id, a label and two node id endpoints.

data Arc =
    Arc {
        arcId        :: Int,
        arcName      :: String,
        startNodeId  :: Int,
        endNodeId    :: Int
    }
 deriving (Show)


-- Tokens are split into NodeTokens and ArcTokens. NodeTokens are sitting at
-- nodes in the workflow graph while ArcTokens are 'in-transit' and are on
-- Arcs.
--
-- The Token class allows NodeTokens and ArcTokens to share an id lookup function

class Token a where
   tokenId   :: a -> Int

data TokenAttr =
    TokenAttr {
        attrSetId      :: Int,
        tokenAttrKey   :: String,
        tokenAttrValue :: String
    }
  deriving (Show)

-- NodeToken represents tokens which are at node
--   The NodeToken constructor takes three parameters
--   token id :: Int          - The id should be unique among node tokens for this process
--   node  id :: Int          - This should be the id of a node in the graph for this process
data NodeToken = NodeToken Int Int
    deriving (Show)

tokenAttrs :: WfProcess a -> NodeToken -> [TokenAttr]
tokenAttrs wfProcess token = (tokenAttrMap wfProcess) Map.! (tokenId token)

attrValue :: WfProcess a -> NodeToken -> String -> Maybe String
attrValue process nodeToken key =
    case (attr) of
        [(TokenAttr _ _ value)] -> Just value
        _                       -> Nothing
    where
        attr  = filter (\tokenAttr -> tokenAttrKey tokenAttr == key) (tokenAttrs process nodeToken)

instance Token (NodeToken) where
    tokenId (NodeToken tokId _) = tokId

instance Eq (NodeToken) where
    tok1 == tok2 = (tokenId tok1) == (tokenId tok2)

-- ArcToken represents tokens which are between nodes (on an arc)

data ArcToken = ArcToken Int Arc NodeToken
    deriving (Show)

parentToken :: ArcToken -> NodeToken
parentToken (ArcToken _ _ token) = token

instance Token (ArcToken) where
    tokenId (ArcToken tokId _ _) = tokId

instance Eq (ArcToken) where
    tok1 == tok2 = (tokenId tok1) == (tokenId tok2)


-- WFGraph
--   Has the set of nodes as well as maps of node input arcs and node output arcs
--   keyed by node id.

data WfGraph =
    WfGraph {
       graphId         :: Int,
       graphName       :: String,
       graphNodes      :: Map.Map Int Node,
       graphInputArcs  :: Map.Map Int [Arc],
       graphOutputArcs :: Map.Map Int [Arc]
    }

-- A WfProcess tracks the current state of the workflow. It has the workflow graph as well
-- as the tokens representing the current state. A slot for user data is also defined.

data WfProcess a =
    WfProcess {
        processId    :: Int,
        nodeTypes    :: Map.Map String (NodeType a),
        wfGraph      :: WfGraph,
        nodeTokens   :: [NodeToken],
        arcTokens    :: [ArcToken],
        tokenAttrMap :: Map.Map Int [TokenAttr],
        userData     :: a
    }

replaceTokenAttrs :: WfProcess a -> NodeToken -> [TokenAttr] -> WfProcess a
replaceTokenAttrs process token attrList =
    process { tokenAttrMap = Map.insert (tokenId token) attrList (tokenAttrMap process) }

class WfEngine a where
    createWfProcess     :: a -> WfGraph     -> Map.Map String (NodeType b) -> b -> IO (WfProcess b)
    createNodeToken     :: a -> WfProcess b -> Node -> [ArcToken] -> IO (WfProcess b, NodeToken)
    createArcToken      :: a -> WfProcess b -> Arc  -> NodeToken  -> IO (WfProcess b, ArcToken)
    completeNodeToken   :: a -> NodeToken   -> IO ()
    completeArcToken    :: a -> ArcToken    -> IO ()
    transactionBoundary :: a -> IO ()
    setTokenAttr        :: a -> WfProcess b -> NodeToken -> String -> String -> IO (WfProcess b)
    removeTokenAttr     :: a -> WfProcess b -> NodeToken -> String -> IO (WfProcess b)

-- showGraph
--   Print prints a graph

showGraph :: WfGraph -> String
showGraph graph = graphName graph ++ ":\n" ++
                  concatMap (\a->show a ++ "\n") (Map.elems (graphNodes graph)) ++ "\n" ++
                  concatMap (\a->show a ++ "\n") (Map.elems (graphInputArcs graph)) ++ "\n" ++
                  concatMap (\a->show a ++ "\n") (Map.elems (graphOutputArcs graph))

-- graphFromNodesAndArcs
--   Generates a WFGraph from a list of Nodes and Arcs

graphFromArcs :: Int -> String -> [Node] -> [Arc] -> WfGraph
graphFromArcs graphId name nodes arcs = WfGraph graphId name nodeMap inputsMap outputsMap
    where
        nodeMap  = Map.fromList $ zip (map nodeId nodes) nodes

        inputsMap             = Map.fromList $ zip (map nodeId nodes) (map inputArcsForNode nodes)
        inputArcsForNode node = filter (\arc -> endNodeId arc == nodeId node) arcs

        outputsMap = Map.fromList $ zip (map nodeId nodes) (map outputArcsForNode nodes)
        outputArcsForNode node = filter (\arc -> startNodeId arc == nodeId node) arcs

-- getTokenForId
--   Given a token id and a workflow instance gives back the actual token
--   corresponding to that id

getNodeTokenForId :: Int -> WfProcess a -> NodeToken
getNodeTokenForId tokId wf =
  head $ filter (\t -> (tokenId t) == tokId) (nodeTokens wf)

-- Convenience lookup methods for the data pointed to by tokens

nodeForToken :: NodeToken -> WfGraph -> Node
nodeForToken (NodeToken _ nodeId) graph = (graphNodes graph) Map.! nodeId

arcForToken :: ArcToken -> Arc
arcForToken  (ArcToken _ arc _)           = arc

-- startWorkflow
--   Given a workflow definition (WfGraph) and initial userData, gives
--   back a new in progress workflow instance for that definition.

startWorkflow :: (WfEngine e) => e -> Map.Map String (NodeType a) -> WfGraph -> a -> IO ( Either String (WfProcess a))
startWorkflow engine nodeTypes graph userData
    | null startNodes       = return $ Left "Error: Workflow has no start node"
    | length startNodes > 1 = return $ Left "Error: Workflow has more than one start node"
    | otherwise             = do wfRun <- createWfProcess engine graph nodeTypes userData
                                 (wfRun,startToken) <- createNodeToken engine wfRun startNode []
                                 wfRun <- acceptWithGuard engine startToken (wfRun { nodeTokens = [startToken] })
                                 return $ Right wfRun
  where
    startNodes = filter (isStartNode) $ Map.elems (graphNodes graph)
    startNode  = head startNodes
    isStartNode node = (nodeName node == "start") && ((wfDepth.nodeSource) node == 0)

isWfComplete :: WfProcess a -> Bool
isWfComplete (WfProcess _ _ _ [] [] _ _) = True
isWfComplete _                         = False

-- removeNodeToken
--   Removes the node token from the list of active node tokens in the given process

removeNodeToken :: NodeToken -> WfProcess a -> WfProcess a
removeNodeToken token wf = wf { nodeTokens = ListUtil.removeFirst (\t->t == token) (nodeTokens wf) }

-- defaultGuard
--   Guard function which always accepts the token

defaultGuard :: a -> b -> GuardResponse
defaultGuard _ _ = AcceptToken


completeDefaultExecution :: (WfEngine engine) => engine -> NodeToken -> WfProcess a -> IO (WfProcess a)
completeDefaultExecution engine token wf = completeExecution engine token [] wf

-- completeExecution
--   Generates a new token for each output node of the current node of the given
--   token.

completeExecution :: (WfEngine e) => e -> NodeToken -> String -> WfProcess a -> IO (WfProcess a)
completeExecution engine token outputArcName wf =
  do completeNodeToken engine token
     foldM (split) newWf outputArcs
  where
    graph        = wfGraph wf
    currentNode  = nodeForToken token graph
    outputArcs   = filter (\arc -> arcName arc == outputArcName ) $
                   (graphOutputArcs graph) Map.! (nodeId currentNode)

    newWf        = removeNodeToken token wf

    split wf arc = do (wf, arcToken) <- createArcToken engine wf arc token
                      acceptToken engine arcToken wf

-- acceptToken
--   Called when a token arrives at a node. The node is checked to see if it requires
--   tokens at all inputs. If it doesn't, the acceptSingle function is called. Otherwise
--   it calls acceptJoin.

acceptToken :: (WfEngine e) => e -> ArcToken -> WfProcess a -> IO (WfProcess a)
acceptToken engine token wf
    | isAcceptSingle = acceptSingle engine token wf
    | otherwise      = acceptJoin   engine token wf
  where
    isAcceptSingle = not $ nodeIsJoin targetNode
    targetNode     = ((graphNodes.wfGraph) wf) Map.! ((endNodeId.arcForToken) token)

-- acceptSingle
--   Called when a node requires only a single incoming token to activate.
--   Moves the token into the node and calls the guard function

acceptSingle :: (WfEngine e) => e -> ArcToken -> WfProcess a -> IO (WfProcess a)
acceptSingle engine token process =
  do (process,newToken) <- createNodeToken engine process node [token]
     completeArcToken engine token
     acceptWithGuard engine newToken process { nodeTokens = newToken:(nodeTokens process) }
  where
    graph = wfGraph process
    node  = (graphNodes graph) Map.! ((endNodeId.arcForToken) token)

-- acceptJoin
--   Called when a node requires that a token exist at all inputs before activating.
--   If the condition is met, joins all the input tokens into a single token in the
--   node then calls the guard function.
--   If all inputs don't yet have inputs, adds the current token to the workflow
--   instance and returns.

acceptJoin :: (WfEngine e) => e -> ArcToken -> WfProcess a -> IO (WfProcess a)
acceptJoin engine token process
    | areAllInputsPresent = do (process,newToken) <- createNodeToken engine process targetNode inputTokens
                               let newProcess = process { nodeTokens = newToken:(nodeTokens process), arcTokens = outputArcTokens }
                               mapM (completeArcToken engine) inputTokens
                               acceptWithGuard engine newToken newProcess
    | otherwise           = return process { arcTokens = allArcTokens }
  where
    allArcTokens          = token:(arcTokens process)
    areAllInputsPresent   = length inputTokens == length inputArcs

    fstInputArcToken arc  = ListUtil.firstMatch (\arcToken -> (arcId.arcForToken) arcToken == arcId arc) allArcTokens

    inputTokens           = ListUtil.removeNothings $ map (fstInputArcToken) inputArcs

    targetNodeId          = (endNodeId.arcForToken) token
    targetNode            = (graphNodes (wfGraph process)) Map.! targetNodeId
    allInputArcs          = (graphInputArcs (wfGraph process)) Map.! targetNodeId
    inputArcs             = filter (\arc-> arcName arc == (arcName.arcForToken) token) allInputArcs
    outputArcTokens       = filter (\t -> not $ elem t inputTokens) (arcTokens process)

-- acceptWithGuard
--   This is only called once the node is ready to fire. The given token is now in the node
--   and exists in the workflow instance.
--   The node guard method is now called and the appropriate action will be taken based on
--   what kind of GuardResponse is returned.

acceptWithGuard :: (WfEngine e) => e -> NodeToken -> WfProcess a -> IO (WfProcess a)
acceptWithGuard engine token wf =
    case (guard token wf) of
        AcceptToken    -> accept engine token wf
        DiscardToken   -> do completeNodeToken engine token
                             return $ removeNodeToken token wf
        (SkipNode arc) -> completeExecution engine token arc wf
    where
        currentNode  = nodeForToken token (wfGraph wf)
        guard        = guardFunction  currNodeType
        accept       = acceptFunction currNodeType
        currNodeType = (nodeTypes wf) Map.! (nodeType currentNode)