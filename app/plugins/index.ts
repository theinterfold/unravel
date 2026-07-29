import { PUB_GAME_ADDRESS } from "@/constants";
import { IconType } from "@aragon/ods";

type PluginItem = {
  /** The URL fragment after /plugins */
  id: string;
  /** The name of the folder within `/plugins` */
  folderName: string;
  /** Title on menu */
  title: string;
  icon?: IconType;
  pluginAddress: string;
};

export const plugins: PluginItem[] = [
  {
    id: "game",
    folderName: "game",
    title: "The Game",
    icon: IconType.APP_MEMBERS,
    pluginAddress: PUB_GAME_ADDRESS,
  },
];
