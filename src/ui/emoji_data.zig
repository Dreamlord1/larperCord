//! Tabela de emoji: a lista Unicode inteira (sem as variações de tom de pele),
//! na ordem do Unicode. GERADO por tools/gen_emoji.py, não edite à mão.
//! Cada linha de `blob`: emoji|nome|palavras em inglês|palavras em português
//! (palavras em minúsculas e sem acento). `offsets[i]` é onde começa a linha i.
const std = @import("std");

pub const Category = struct { name: []const u8, name_en: []const u8, icon: []const u8, first: u16, count: u16 };

pub const categories = [_]Category{
    .{ .name = "Carinhas", .name_en = "Smileys", .icon = "😀", .first = 0, .count = 172 },
    .{ .name = "Pessoas", .name_en = "People", .icon = "👋", .first = 172, .count = 390 },
    .{ .name = "Natureza", .name_en = "Nature", .icon = "🐵", .first = 562, .count = 161 },
    .{ .name = "Comida", .name_en = "Food", .icon = "🍇", .first = 723, .count = 132 },
    .{ .name = "Viagem", .name_en = "Travel", .icon = "🌍", .first = 855, .count = 221 },
    .{ .name = "Atividades", .name_en = "Activities", .icon = "🎃", .first = 1076, .count = 85 },
    .{ .name = "Objetos", .name_en = "Objects", .icon = "👓", .first = 1161, .count = 268 },
    .{ .name = "Símbolos", .name_en = "Symbols", .icon = "🏧", .first = 1429, .count = 224 },
    .{ .name = "Bandeiras", .name_en = "Flags", .icon = "🏁", .first = 1653, .count = 270 },
};

pub const count: u16 = 1923;

pub const offsets = [_]u32{
    0, 92, 234, 374, 490, 639, 758, 877, 999, 1123, 1226, 1349, 1458, 1547, 1686, 1794,
    1933, 2091, 2199, 2338, 2407, 2540, 2714, 2877, 3010, 3128, 3242, 3451, 3553, 3758, 3865, 3962,
    4099, 4290, 4427, 4555, 4639, 4742, 4867, 5007, 5117, 5225, 5322, 5464, 5572, 5689, 5800, 5930,
    6047, 6148, 6261, 6356, 6512, 6620, 6692, 6792, 6872, 6949, 7044, 7171, 7292, 7401, 7529, 7634,
    7731, 7844, 7958, 8061, 8174, 8278, 8415, 8529, 8633, 8757, 8855, 8983, 9087, 9154, 9249, 9392,
    9473, 9574, 9702, 9833, 9920, 10024, 10132, 10237, 10373, 10521, 10658, 10739, 10854, 10996, 11134, 11216,
    11339, 11458, 11546, 11678, 11804, 11922, 12021, 12108, 12207, 12329, 12420, 12488, 12600, 12729, 12852, 12926,
    13056, 13131, 13216, 13313, 13396, 13471, 13529, 13641, 13702, 13790, 13920, 14043, 14180, 14275, 14375, 14471,
    14576, 14667, 14807, 14951, 15094, 15202, 15303, 15422, 15522, 15616, 15702, 15806, 15890, 15990, 16104, 16201,
    16302, 16403, 16464, 16549, 16622, 16705, 16772, 16835, 16936, 17017, 17079, 17145, 17229, 17291, 17356, 17452,
    17532, 17622, 17703, 17792, 17894, 17978, 18018, 18120, 18235, 18346, 18463, 18571, 18648, 18732, 18845, 18977,
    19078, 19201, 19298, 19388, 19484, 19576, 19713, 19850, 19920, 20028, 20132, 20228, 20337, 20501, 20580, 20655,
    20726, 20865, 21008, 21146, 21219, 21394, 21505, 21642, 21734, 21856, 21977, 22098, 22193, 22285, 22364, 22431,
    22530, 22655, 22739, 22819, 22925, 23004, 23085, 23157, 23254, 23311, 23416, 23489, 23562, 23618, 23671, 23730,
    23872, 23931, 23981, 24100, 24175, 24214, 24253, 24319, 24361, 24405, 24462, 24546, 24626, 24676, 24734, 24798,
    24837, 24954, 25028, 25102, 25177, 25243, 25285, 25331, 25377, 25409, 25477, 25523, 25569, 25619, 25669, 25719,
    25769, 25805, 25843, 25967, 26059, 26123, 26196, 26265, 26374, 26488, 26593, 26696, 26790, 26874, 27008, 27135,
    27268, 27388, 27498, 27593, 27744, 27888, 28007, 28115, 28225, 28334, 28418, 28474, 28536, 28656, 28787, 28918,
    29042, 29175, 29316, 29426, 29536, 29659, 29769, 29897, 30039, 30093, 30194, 30277, 30348, 30443, 30536, 30592,
    30661, 30736, 30794, 30867, 30946, 31000, 31069, 31131, 31234, 31331, 31435, 31540, 31647, 31748, 31858, 31998,
    32146, 32222, 32326, 32447, 32539, 32661, 32792, 32858, 32949, 33034, 33075, 33180, 33266, 33305, 33380, 33474,
    33525, 33609, 33710, 33777, 33893, 33999, 34092, 34186, 34307, 34392, 34486, 34615, 34673, 34743, 34844, 34921,
    35066, 35170, 35307, 35401, 35453, 35537, 35619, 35702, 35791, 35914, 36008, 36128, 36201, 36280, 36393, 36459,
    36545, 36618, 36720, 36828, 36924, 37048, 37169, 37294, 37354, 37434, 37511, 37584, 37647, 37734, 37830, 37917,
    38019, 38117, 38194, 38260, 38325, 38381, 38431, 38486, 38564, 38632, 38697, 38775, 38817, 38854, 38909, 38968,
    39021, 39084, 39130, 39181, 39260, 39316, 39377, 39442, 39545, 39670, 39796, 39911, 40033, 40145, 40259, 40355,
    40439, 40547, 40618, 40696, 40770, 40826, 40890, 40960, 41065, 41138, 41217, 41290, 41370, 41446, 41555, 41649,
    41758, 41846, 41980, 42072, 42216, 42326, 42469, 42573, 42722, 42830, 42964, 43068, 43201, 43299, 43438, 43540,
    43670, 43780, 43912, 43983, 44061, 44135, 44227, 44338, 44404, 44515, 44632, 44758, 44888, 44991, 45062, 45138,
    45250, 45325, 45405, 45481, 45568, 45621, 45709, 45781, 45869, 45970, 46046, 46114, 46211, 46293, 46375, 46477,
    46561, 46635, 46740, 46872, 46990, 47136, 47272, 47387, 47538, 47616, 47699, 47803, 47938, 48053, 48185, 48295,
    48416, 48539, 48635, 48738, 48850, 48969, 49104, 49245, 49332, 49453, 49578, 49683, 49803, 49931, 50059, 50171,
    50288, 50379, 50473, 50609, 50739, 50858, 50986, 51047, 51114, 51177, 51248, 51357, 51437, 51513, 51597, 51662,
    51729, 51812, 51893, 51978, 52039, 52102, 52181, 52258, 52339, 52408, 52479, 52566, 52651, 52740, 52785, 52846,
    52893, 52956, 53021, 53070, 53135, 53186, 53253, 53322, 53415, 53520, 53637, 53737, 53814, 53942, 54122, 54222,
    54352, 54437, 54526, 54591, 54624, 54666, 54718, 54780, 54814, 54888, 54987, 55033, 55080, 55140, 55201, 55270,
    55303, 55389, 55444, 55494, 55525, 55567, 55632, 55699, 55764, 55822, 55885, 55930, 55964, 56017, 56081, 56117,
    56185, 56219, 56271, 56298, 56327, 56390, 56440, 56480, 56533, 56633, 56748, 56804, 56839, 56878, 56949, 56995,
    57044, 57123, 57167, 57201, 57264, 57330, 57394, 57435, 57484, 57545, 57581, 57628, 57694, 57724, 57780, 57855,
    57897, 57940, 58011, 58074, 58167, 58229, 58269, 58306, 58400, 58487, 58589, 58619, 58670, 58743, 58774, 58809,
    58862, 58900, 58955, 59007, 59065, 59128, 59187, 59252, 59339, 59397, 59487, 59534, 59583, 59624, 59675, 59721,
    59786, 59835, 59951, 60011, 60088, 60131, 60183, 60225, 60300, 60364, 60425, 60468, 60499, 60548, 60637, 60696,
    60769, 60848, 60917, 60968, 61012, 61071, 61117, 61166, 61278, 61323, 61358, 61406, 61453, 61533, 61577, 61644,
    61713, 61787, 61850, 61930, 61988, 62042, 62106, 62173, 62279, 62371, 62444, 62510, 62542, 62618, 62671, 62717,
    62760, 62796, 62881, 62962, 63052, 63154, 63255, 63324, 63378, 63475, 63508, 63584, 63695, 63790, 63872, 63949,
    64026, 64107, 64176, 64252, 64286, 64315, 64357, 64430, 64494, 64567, 64605, 64656, 64701, 64756, 64831, 64869,
    64900, 64971, 65047, 65127, 65172, 65225, 65276, 65329, 65371, 65446, 65499, 65560, 65623, 65697, 65783, 65846,
    65918, 66003, 66043, 66075, 66107, 66144, 66204, 66243, 66320, 66389, 66487, 66567, 66650, 66715, 66789, 66862,
    66903, 66976, 67042, 67091, 67148, 67237, 67324, 67424, 67468, 67546, 67623, 67664, 67759, 67809, 67860, 67914,
    67988, 68072, 68124, 68153, 68242, 68355, 68422, 68491, 68581, 68660, 68701, 68749, 68808, 68858, 68933, 69013,
    69103, 69168, 69244, 69319, 69402, 69498, 69581, 69660, 69758, 69849, 69941, 70039, 70127, 70231, 70315, 70427,
    70511, 70577, 70651, 70711, 70817, 70920, 70997, 71062, 71140, 71181, 71223, 71291, 71349, 71425, 71480, 71560,
    71620, 71732, 71809, 71948, 72025, 72105, 72228, 72303, 72402, 72514, 72583, 72679, 72765, 72840, 72930, 72992,
    73043, 73102, 73224, 73316, 73347, 73422, 73483, 73545, 73669, 73792, 73937, 74043, 74110, 74159, 74238, 74324,
    74367, 74457, 74517, 74564, 74608, 74687, 74728, 74797, 74893, 74931, 75017, 75095, 75163, 75221, 75278, 75315,
    75343, 75402, 75460, 75544, 75611, 75697, 75758, 75821, 75849, 75879, 75930, 76030, 76088, 76194, 76230, 76320,
    76396, 76471, 76535, 76615, 76675, 76727, 76784, 76855, 76954, 77006, 77054, 77104, 77173, 77266, 77324, 77453,
    77529, 77627, 77722, 77795, 77857, 77963, 78074, 78166, 78282, 78375, 78450, 78519, 78614, 78720, 78836, 78876,
    78936, 79009, 79065, 79112, 79159, 79278, 79342, 79389, 79472, 79567, 79628, 79672, 79789, 79864, 79974, 80002,
    80087, 80139, 80251, 80334, 80417, 80480, 80571, 80612, 80687, 80750, 80820, 80917, 81007, 81079, 81120, 81170,
    81221, 81306, 81386, 81442, 81491, 81555, 81646, 81701, 81829, 81944, 82072, 82122, 82223, 82304, 82356, 82443,
    82513, 82542, 82612, 82709, 82776, 82839, 82899, 82967, 83067, 83165, 83279, 83368, 83408, 83473, 83582, 83749,
    83829, 83903, 83957, 84048, 84109, 84159, 84215, 84337, 84394, 84480, 84532, 84609, 84692, 84770, 84825, 84882,
    84948, 85007, 85062, 85125, 85182, 85250, 85303, 85357, 85415, 85471, 85527, 85585, 85642, 85706, 85763, 85820,
    85881, 85939, 85996, 86060, 86121, 86185, 86282, 86377, 86471, 86521, 86610, 86703, 86794, 86861, 86955, 87079,
    87260, 87327, 87390, 87499, 87568, 87651, 87713, 87810, 87871, 87928, 87959, 88055, 88183, 88287, 88365, 88453,
    88536, 88613, 88722, 88774, 88827, 88907, 88978, 89038, 89136, 89218, 89339, 89438, 89539, 89622, 89718, 89807,
    89873, 89955, 89986, 90055, 90114, 90239, 90327, 90419, 90516, 90596, 90669, 90761, 90861, 90938, 91042, 91142,
    91233, 91315, 91376, 91496, 91589, 91652, 91739, 91833, 91917, 91960, 92050, 92119, 92196, 92285, 92378, 92474,
    92539, 92608, 92666, 92750, 92813, 92920, 93006, 93059, 93126, 93172, 93233, 93308, 93378, 93442, 93509, 93564,
    93631, 93745, 93809, 93880, 93952, 94047, 94149, 94252, 94298, 94331, 94400, 94471, 94510, 94551, 94641, 94701,
    94803, 94884, 94988, 95054, 95130, 95202, 95259, 95356, 95429, 95526, 95605, 95680, 95754, 95828, 95895, 95958,
    96022, 96115, 96235, 96341, 96442, 96539, 96597, 96697, 96749, 96808, 96849, 96920, 97003, 97078, 97176, 97234,
    97282, 97323, 97370, 97412, 97462, 97496, 97538, 97578, 97626, 97698, 97758, 97816, 97875, 97965, 98068, 98133,
    98204, 98285, 98374, 98438, 98523, 98591, 98710, 98798, 98881, 98981, 99073, 99153, 99236, 99322, 99417, 99497,
    99571, 99700, 99756, 99861, 99984, 100072, 100145, 100207, 100263, 100370, 100476, 100591, 100706, 100799, 100849, 100917,
    100963, 101069, 101137, 101193, 101257, 101355, 101431, 101508, 101591, 101687, 101736, 101813, 101882, 101951, 102023, 102095,
    102209, 102275, 102324, 102372, 102466, 102553, 102627, 102689, 102781, 102899, 102957, 103053, 103088, 103140, 103181, 103281,
    103379, 103462, 103555, 103640, 103704, 103769, 103842, 103912, 103987, 104040, 104085, 104148, 104259, 104318, 104403, 104477,
    104521, 104571, 104665, 104735, 104794, 104910, 105019, 105056, 105142, 105202, 105324, 105383, 105510, 105576, 105664, 105751,
    105829, 105904, 105983, 106021, 106063, 106144, 106197, 106297, 106344, 106434, 106511, 106575, 106627, 106679, 106755, 106843,
    106916, 107004, 107079, 107158, 107273, 107370, 107448, 107559, 107641, 107700, 107818, 107937, 108039, 108140, 108192, 108342,
    108498, 108685, 108914, 108995, 109104, 109132, 109218, 109291, 109337, 109390, 109450, 109538, 109613, 109665, 109736, 109827,
    109936, 109986, 110110, 110184, 110273, 110325, 110492, 110645, 110725, 110770, 110815, 110911, 110957, 111050, 111102, 111213,
    111275, 111370, 111462, 111519, 111578, 111650, 111752, 111867, 111923, 111983, 112067, 112138, 112181, 112228, 112323, 112438,
    112476, 112567, 112636, 112716, 112806, 112840, 112932, 113008, 113063, 113148, 113187, 113252, 113333, 113434, 113490, 113601,
    113647, 113716, 113793, 113862, 113905, 113948, 114000, 114099, 114194, 114251, 114353, 114408, 114505, 114594, 114690, 114771,
    114868, 114942, 115023, 115089, 115118, 115185, 115257, 115322, 115361, 115435, 115475, 115560, 115634, 115684, 115720, 115793,
    115864, 115966, 116041, 116095, 116171, 116253, 116294, 116352, 116416, 116498, 116570, 116672, 116763, 116839, 116914, 116992,
    117064, 117151, 117198, 117245, 117315, 117435, 117528, 117644, 117726, 117836, 117929, 118024, 118096, 118178, 118264, 118347,
    118417, 118528, 118620, 118675, 118793, 118880, 118970, 119065, 119160, 119275, 119395, 119514, 119628, 119733, 119815, 119918,
    119986, 120113, 120198, 120328, 120418, 120548, 120639, 120780, 120885, 120984, 121149, 121298, 121446, 121603, 121769, 121961,
    122051, 122146, 122200, 122308, 122383, 122478, 122564, 122596, 122683, 122766, 122839, 122904, 122977, 123081, 123141, 123223,
    123324, 123389, 123443, 123494, 123543, 123603, 123642, 123689, 123766, 123824, 123898, 123969, 124029, 124078, 124158, 124311,
    124404, 124532, 124631, 124733, 124868, 124979, 125084, 125193, 125329, 125456, 125577, 125715, 125842, 125921, 125984, 126053,
    126106, 126182, 126292, 126404, 126515, 126618, 126706, 126838, 126905, 126969, 127046, 127148, 127220, 127300, 127386, 127491,
    127556, 127655, 127759, 127882, 127993, 128098, 128235, 128315, 128400, 128492, 128595, 128732, 128796, 128896, 128949, 129111,
    129198, 129298, 129426, 129529, 129599, 129718, 129787, 129883, 130014, 130110, 130206, 130243, 130318, 130410, 130520, 130571,
    130602, 130630, 130675, 130717, 130761, 130807, 130854, 130900, 130944, 130990, 131036, 131081, 131109, 131281, 131406, 131477,
    131549, 131656, 131761, 131869, 131974, 132025, 132101, 132184, 132278, 132344, 132403, 132458, 132513, 132619, 132674, 132751,
    132840, 132914, 132976, 133069, 133196, 133336, 133466, 133575, 133704, 133811, 133924, 134033, 134145, 134268, 134386, 134484,
    134610, 134716, 134851, 134962, 135072, 135137, 135202, 135261, 135366, 135425, 135486, 135555, 135626, 135689, 135756, 135823,
    135884, 135946, 136015, 136078, 136168, 136253, 136341, 136430, 136539, 136650, 136752, 136856, 137024, 137147, 137318, 137437,
    137583, 137738, 137878, 137947, 138059, 138181, 138309, 138433, 138536, 138604, 138681, 138796, 138912, 139012, 139062, 139094,
    139152, 139192, 139242, 139276, 139308, 139340, 139370, 139408, 139444, 139490, 139522, 139558, 139586, 139630, 139668, 139724,
    139758, 139796, 139828, 139870, 139904, 139936, 139968, 139996, 140041, 140073, 140103, 140135, 140195, 140225, 140257, 140287,
    140331, 140365, 140397, 140427, 140457, 140519, 140567, 140633, 140687, 140727, 140778, 140820, 140848, 140882, 140913, 140947,
    140999, 141030, 141068, 141094, 141132, 141164, 141214, 141244, 141283, 141323, 141365, 141399, 141431, 141465, 141519, 141551,
    141597, 141629, 141661, 141689, 141735, 141767, 141798, 141832, 141881, 141913, 141939, 141989, 142027, 142071, 142111, 142139,
    142189, 142221, 142253, 142297, 142331, 142359, 142395, 142431, 142461, 142491, 142529, 142581, 142611, 142703, 142739, 142765,
    142809, 142839, 142885, 142956, 142990, 143022, 143050, 143082, 143128, 143164, 143196, 143226, 143266, 143294, 143372, 143398,
    143424, 143456, 143487, 143517, 143549, 143579, 143610, 143638, 143676, 143710, 143744, 143776, 143825, 143865, 143902, 143932,
    143978, 144016, 144042, 144074, 144109, 144153, 144189, 144221, 144253, 144289, 144327, 144357, 144385, 144417, 144447, 144479,
    144517, 144554, 144592, 144642, 144684, 144710, 144756, 144790, 144828, 144894, 144932, 144970, 145008, 145036, 145072, 145106,
    145136, 145166, 145200, 145238, 145270, 145314, 145342, 145388, 145420, 145456, 145496, 145526, 145554, 145582, 145608, 145648,
    145674, 145704, 145730, 145780, 145830, 145870, 145904, 145934, 145991, 146041, 146081, 146145, 146179, 146207, 146241, 146269,
    146301, 146333, 146363, 146396, 146426, 146468, 146516, 146554, 146582, 146612, 146648, 146715, 146749, 146805, 146839, 146881,
    146919, 146951, 146983, 147017, 147057, 147111, 147151, 147193, 147221, 147256, 147306, 147366, 147392, 147472, 147498, 147532,
    147570, 147602, 147642, 147684, 147716, 147744, 147778, 147828, 147858, 147888, 147922, 147954, 147984, 148042, 148088, 148141,
    148173, 148211, 148253, 148316, 148352, 148414, 148468, 148500, 148532, 148578, 148606, 148636, 148664, 148696, 148738, 148768,
    148802, 148854, 148908, 148956,
};

pub const blob =
    \\😀|grinning|smile happy grinning face|rosto risonho engracado feliz lol rindo risada riso
    \\😃|smiley|happy joy haha grinning face with big eyes|rosto risonho com olhos bem abertos aberto boca feliz olhos arregalados risada risonho
    \\😄|smile|happy joy laugh pleased grinning face with smiling eyes|rosto risonho com olhos sorridentes aberta boca engracado feliz haha lol
    \\😁|grin|beaming face with smiling eyes|rosto contente com olhos sorridentes feliz olho olhos sorrindo rindo rosto
    \\😆|laughing|satisfied happy haha grinning squinting face|rosto risonho com olhos semicerrados gargalhada gargalhando hahaha kkk olhos fechados rir
    \\😅|sweat_smile|hot grinning face with sweat|rosto risonho com gota de suor estressada estressado nervoso rindo rosto
    \\🤣|rofl|lol laughing rolling on the floor laughing|rolando no chao de rir chao choro engracada feliz gargalhada haha
    \\😂|joy|tears face with tears of joy|rosto chorando de rir alegria chorando de rir engracada engracado gargalhada hahaha
    \\🙂|slightly_smiling_face|slightly smiling face|rosto levemente sorridente feliz rosto rosto sorrindo sorriso sorriso leve
    \\🙃|upside_down_face|upside-down face|rosto de cabeca para baixo de cabeca para baixo rosto invertido
    \\🫠|melting_face|sarcasm dread melting face|rosto derretendo calor derretendo derreter desaparecer dissolver envergonhada
    \\🫫|cracking_face|cracking face|rosto rachando decepcao quebrar quebrar a cara resiliencia revelacao tensao
    \\😉|wink|flirt winking face|rosto com olho piscando flerte piscada rosto rosto piscando
    \\😊|blush|proud smiling face with smiling eyes|rosto sorridente com olhos sorridentes alegre encabulada envergonhada feliz fofo ruborizar
    \\😇|innocent|angel smiling face with halo|rosto sorridente com aureola anjinho anjo aureola inocente rosto
    \\🥰|smiling_face_with_three_hearts|love smiling face with hearts|rosto sorridente com 3 coracoes amando amei amo apaixonada coracao crush
    \\😍|heart_eyes|love crush smiling face with heart-eyes|rosto sorridente com olhos de coracao amor apaixonado coracao olhar apaixonado olhos olhos de coracao
    \\🤩|star_struck|eyes star-struck|rosto com olhar maravilhado estrela gargalhando olhos rosto super animada
    \\😘|kissing_heart|flirt face blowing a kiss|rosto mandando um beijo beijo flerte jogando beijos mandando beijo rosto rosto jogando beijos
    \\😗|kissing|kissing face|rosto beijando beijo rosto rosto com beijo
    \\☺️|relaxed|blush pleased smiling face|rosto sorridente corada corado relaxado rosto rosto sorrindo rosto sorrindo nao preenchido
    \\😚|kissing_closed_eyes|kissing face with closed eyes|rosto beijando com olhos fechados beijando beijando com os olhos fechados beijinho mandando beijo olhos fechados rosto
    \\😙|kissing_smiling_eyes|kissing face with smiling eyes|rosto beijando com olhos sorridentes beijar e sorrir beijinho beijos flerte mandando beijo olhos sorrindo
    \\🥲|smiling_face_with_tear|smiling face with tear|rosto sorridente com lagrima aliviada chorar contente emocionado felicidade feliz
    \\😋|yum|tongue lick face savoring food|rosto saboreando comida apetitoso comida gostosa delicioso gostoso nham rosto
    \\😛|stuck_out_tongue|face with tongue|rosto mostrando a lingua lingua para fora rosto rosto com lingua para fora
    \\😜|stuck_out_tongue_winking_eye|prank silly winking face with tongue|rosto piscando e com lingua para fora brincadeira lingua para fora com piscadela piscadela piscando e mostrando a lingua provocacao rosto
    \\🤪|zany_face|goofy wacky zany face|rosto bizarro cara de maluco doida doido excentrico grande louca
    \\😝|stuck_out_tongue_closed_eyes|prank squinting face with tongue|rosto com olhos semicerrados e lingua para fora eca horrivel lingua para fora lingua para fora com os olhos fechados olhos fechados rosto
    \\🤑|money_mouth_face|rich money-mouth face|rosto com cifroes avarenta caro cifrao dinheiro ganancia grana
    \\🤗|hugs|smiling face with open hands|rosto abracando abraco carinho feliz maos abracando rosto
    \\🤭|hand_over_mouth|quiet whoops face with hand over mouth|rosto com a mao sobre a boca hehe ops risadinha risonho sorriso envergonhado
    \\🫢|face_with_open_eyes_and_hand_over_mouth|gasp shock face with open eyes and hand over mouth|rosto com olhos abertos e mao sobre a boca assustada chocada descrenca em choque espanto nossa
    \\🫣|face_with_peeking_eye|face with peeking eye|rosto com olho espiando cativada cativado envergonhada envergonhado esconder espiadinha
    \\🤫|shushing_face|silence quiet shushing face|rosto fazendo sinal de silencio faca silencio fica quieta quieta quieto silencio
    \\🤔|thinking|thinking face|rosto pensativo curiosa curioso duvida hmm ideia ideias
    \\🫡|saluting_face|respect saluting face|rosto saudando boa sorte exercito ok respeito saudacao senhor
    \\🤐|zipper_mouth_face|silence hush zipper-mouth face|rosto com boca de ziper boca fechada calada calado quieta quieto rosto
    \\🤨|raised_eyebrow|suspicious face with raised eyebrow|rosto com sobrancelha levantada cetica ceticismo cetico confusa confuso desconfiada
    \\😐|neutral_face|meh neutral face|rosto neutro neutro putz rosto rosto sem emocao sem comentarios sem emocao
    \\😑|expressionless|expressionless face|rosto inexpressivo aff inespressiva inespressivo nada a dizer rosto
    \\😶|no_mouth|mute silence face without mouth|rosto sem boca calada calado quieto rosto sem boca
    \\🫥|dotted_line_face|invisible dotted line face|rosto com linha pontilhada deprimida desaparecer esconder escondido indiferenca introvertido
    \\😶‍🌫️|face_in_clouds|face in clouds|rosto nas nuvens cabeca nas nuvens distraido rosto no nevoeiro
    \\😏|smirk|smug smirking face|rosto com sorriso maroto flerte rosto sorriso maldoso sorriso malicioso sorriso maroto
    \\😒|unamused|meh unamused face|rosto aborrecido aff blase nada engracado nao achou graca nao esta feliz rosto
    \\🙄|roll_eyes|face with rolling eyes|rosto com olhos revirados olhando para cima olhos revirando os olhos rolando os olhos rosto
    \\😬|grimacing|grimacing face|rosto expressando desagrado careta fazendo careta rosto rosto fazendo careta sem graca
    \\😮‍💨|face_exhaling|face exhaling|rosto exalando alivio assobio assopro cansaco cansada choque
    \\🤥|lying_face|liar lying face|rosto de mentiroso mentindo mentira mentiroso nariz crescendo pinocchio pinoquio
    \\🫨|shaking_face|shock shaking face|rosto tremendo choque louco loucura meu deus panico rosto
    \\🙂‍↔️|head_shaking_horizontally|head shaking horizontally|cabeca virando de um lado para o outro balancar cabeca balancando na horizontal nao negar
    \\🙂‍↕️|head_shaking_vertically|head shaking vertically|cabeca balancando na vertical confirmacao sim
    \\😌|relieved|whew relieved face|rosto aliviado alivio em paz rosto zen
    \\😔|pensive|pensive face|rosto deprimido abatido chateado deprimido desanimado pensativo pra baixo
    \\😪|sleepy|tired sleepy face|rosto sonolento cara de sono rosto rosto com sono
    \\🤤|drooling_face|drooling face|rosto babando babando babar rosto salivando
    \\😴|sleeping|zzz sleeping face|rosto dormindo boa noite cama cansada cansado cochilo dormindo
    \\🫩|face_with_bags_under_eyes|face with bags under eyes|rosto com olheiras cansaco cansada cansado dorminhoco exausta exausto
    \\😷|mask|sick ill face with medical mask|rosto com mascara medica doente gripado mascara mascara medica resfriado rosto
    \\🤒|face_with_thermometer|sick face with thermometer|rosto com termometro de cama doente febre febril rosto
    \\🤕|face_with_head_bandage|hurt face with head-bandage|rosto com atadura na cabeca acidentado doente ferimento machucado rosto
    \\🤢|nauseated_face|sick barf disgusted nauseated face|rosto nauseado doente enjoado enjoo nausea vomito
    \\🤮|vomiting_face|barf sick face vomiting|rosto vomitando doente nojenta nojento nojo vomitando
    \\🤧|sneezing_face|achoo sick sneezing face|rosto espirrando de cama doente espirrando espirro gripado resfriado
    \\🥵|hot_face|heat sweating hot face|rosto fervendo de calor calor febre febril insolacao lingua de fora ofegante
    \\🥶|cold_face|freezing ice cold face|rosto gelado abaixo de zero azul congelando congelei frio gelado
    \\🥴|woozy_face|groggy woozy face|rosto embriagado alcoolizado bebada bebado boca ondulada embriagada embriagado
    \\😵|dizzy_face|face with crossed-out eyes|rosto atordoado acabado atordoado doente morto rosto tontura
    \\😵‍💫|face_with_spiral_eyes|face with spiral eyes|rosto com olhos em espiral caramba confuso desnorteado eita espirais hipnotizado
    \\🤯|exploding_head|mind blown exploding head|cabeca explodindo cabeca chocada chocado chocante choque explodindo
    \\🤠|cowboy_hat_face|cowboy hat face|rosto com chapeu de cauboi cara cara de cauboi cauboi cowboy rosto
    \\🥳|partying_face|celebration birthday partying face|rosto festivo animacao aniversario apito chapeu comemoracao comemorar
    \\🥸|disguised_face|disguised face|rosto disfarcado bigode disfarce espiao incognito nariz oculos
    \\😎|sunglasses|cool smiling face with sunglasses|rosto sorridente com oculos escuros muito sol na boa oculos escuros rosto sol
    \\🤓|nerd_face|geek glasses nerd face|rosto de nerd cdf esperto estudioso inteligencia inteligente nerd
    \\🧐|monocle_face|face with monocle|rosto com monoculo conservador
    \\😕|confused|confused face|rosto confuso confuso indeciso nao entendi nao tenho certeza rosto
    \\🫤|face_with_diagonal_mouth|confused face with diagonal mouth|rosto com boca diagonal cetico confusao decepcao desapontado duvida frustracao
    \\😟|worried|nervous worried face|rosto preocupado decepcionado preocupado rosto
    \\🙁|slightly_frowning_face|slightly frowning face|rosto meio triste rosto triste tristeza tristinho
    \\☹️|frowning_face|frowning face|rosto descontente decepcao decepcionado descontente insatisfeito rosto rosto de desaprovacao
    \\😮|open_mouth|surprise impressed wow face with open mouth|rosto com boca aberta boca boca aberta boquiaberto empatia pasmo rosto
    \\😯|hushed|silence speechless hushed face|rosto surpreso espantado rosto surpreso uau
    \\😲|astonished|amazed gasp astonished face|rosto espantado chocado estupefato rosto totalmente chocado
    \\😳|flushed|flushed face|rosto ruborizado atordoado deslumbrado horrorizado impressionado rosto ruborizado
    \\🫪|distorted_face|distorted face|rosto distorcido ansiedade chocado inchado panico surpreso vulneravel
    \\🥺|pleading_face|puppy eyes pleading face|rosto implorando implorando olhar de cachorrinho olhos grandes perdao por favor por que nao
    \\🥹|face_holding_back_tears|tears gratitude face holding back tears|rosto segurando as lagrimas admiracao alegria chorar com raiva emocao gratidao
    \\😦|frowning|frowning face with open mouth|rosto franzido com boca aberta aberta assustado boca decepcionado inesperado rosto assustado
    \\😧|anguished|stunned anguished face|rosto angustiado angustiado rosto sofrendo
    \\😨|fearful|scared shocked oops fearful face|rosto amedrontado ansiedade assustado com medo medo preocupado rosto
    \\😰|cold_sweat|nervous anxious face with sweat|rosto ansioso com gota de suor boca aberta nervoso rosto rosto azul com suor frio suando frio
    \\😥|disappointed_relieved|phew sweat nervous sad but relieved face|rosto triste, mas aliviado aliviado decepcionado nao rosto triste ufa
    \\😢|cry|sad tear crying face|rosto chorando chorando choro lagrimas rosto triste
    \\😭|sob|sad cry bawling loudly crying face|rosto chorando aos berros chorando chorando alto chorar infeliz lagrimas rosto
    \\😱|scream|horror shocked face screaming in fear|rosto gritando de medo assustada assustado gritando grito medo rosto
    \\😖|confounded|confounded face|rosto perplexo bravo frustrado indignado perplexo rosto
    \\😣|persevere|struggling persevering face|rosto perseverante concentracao concentrado dor de cabeca foco perseveranca perseverante
    \\😞|disappointed|sad disappointed face|rosto desapontado decepcao desapontado desapontamento rosto rosto decepcionado triste
    \\😓|sweat|downcast face with sweat|rosto cabisbaixo com gota de suor rosto rosto com suor frio suando frio suor frio
    \\😩|weary|tired weary face|rosto desolado aborrecido cansado cansei decepcionado desolado exausto
    \\😫|tired_face|upset whine tired face|rosto cansado cansado desesperado exausto rosto
    \\🥱|yawning_face|yawning face|rosto bocejando bocejo cansada cansado com sono entediada entediado
    \\😤|triumph|smug face with steam from nose|rosto soltando vapor pelo nariz brava bravo furiosa furioso irritada irritado
    \\😡|rage|pout angry enraged face|rosto furioso bravo furioso irado rosto vermelho zangado
    \\😠|angry|mad annoyed angry face|rosto zangado irado rosto zangado
    \\🤬|cursing_face|foul face with symbols on mouth|rosto com simbolos na boca boca censurado fala mal rosto rude
    \\😈|smiling_imp|devil evil horns smiling face with horns|rosto sorridente com chifres cara chifres diabinho diabo malicia rosto
    \\👿|imp|angry devil evil horns angry face with horns|rosto zangado com chifres bravo chifres demonio diabinho diabo rosto
    \\💀|skull|dead danger poison skull|caveira conto corpo fadas morte rosto
    \\☠️|skull_and_crossbones|danger pirate skull and crossbones|caveira e ossos cruzados caveira morte ossos ossos cruzados pirata
    \\💩|hankey|poop shit crap pile of poo|coco estrume excremento fezes pilha
    \\🤡|clown_face|clown face|rosto de palhaco cara circo engracado palhaco piada rosto
    \\👹|japanese_ogre|monster ogre|ogro assustador conto de fadas demoniaco japones malvado mascara
    \\👺|japanese_goblin|goblin|duende japones bravo conto duende fadas goblin japones
    \\👻|ghost|halloween ghost|fantasma assombracao assombrado buu conto fadas
    \\👽|alien|ufo alien|alienigena extraterrestre ovni rosto
    \\👾|space_invader|game retro alien monster|monstro alienigena alien e.t. extraterrestre game invasores monstro
    \\🤖|robot|robot|rosto de robo monstro robo robotizado rosto
    \\😺|smiley_cat|grinning cat|rosto de gato sorrindo aberta animal boca feliz gato rosto
    \\😸|smile_cat|grinning cat with smiling eyes|rosto de gato sorrindo com olhos sorridentes gato rindo riso rosto sorrindo sorriso
    \\😹|joy_cat|cat with tears of joy|rosto de gato com lagrimas de alegria alegria chorando choro engracado felicidade feliz
    \\😻|heart_eyes_cat|smiling cat with heart-eyes|rosto de gato sorridente com olhos de coracao adorei amor apaixonado coracao gato paixao
    \\😼|smirk_cat|cat with wry smile|rosto de gato com sorriso ironico gato ironico rosto sorriso
    \\😽|kissing_cat|kissing cat|rosto de gato mandando um beijo beijando beijo fechado gato olho rosto
    \\🙀|scream_cat|horror weary cat|rosto de gato desolado choque desolado gato meu deus oh! rosto
    \\😿|crying_cat_face|sad tear crying cat|rosto de gato chorando chorando choro gato lagrima rosto triste
    \\😾|pouting_cat|pouting cat|rosto de gato mal-humorado bico bravo gato mal-humorado rosto
    \\🙈|see_no_evil|monkey blind ignore see-no-evil monkey|macaco que nao ve nada envergonhado macaco nao veja o mal nao vi nada olhos tapados
    \\🙉|hear_no_evil|monkey deaf hear-no-evil monkey|macaco que nao ouve nada macaco nao ouca o mal nao ouco nao ouve nada nao quero ouvir ouvidos
    \\🙊|speak_no_evil|monkey mute hush speak-no-evil monkey|macaco que nao fala nada animal boca tapada macaco nao nao fale nada nao posso contar
    \\💌|love_letter|email envelope love letter|carta de amor carta coracao correspondencia com coracao romance
    \\💘|cupid|love heart heart with arrow|coracao com flecha amor coracao cupido emocao flecha flechado
    \\💝|gift_heart|chocolates heart with ribbon|coracao com fita amor aniversario coracao dia dos namorados fita presente
    \\💖|sparkling_heart|sparkling heart|coracao brilhante amor brilhante coracao emocao emocionante s2
    \\💗|heartpulse|growing heart|coracao crescendo amor animado batendo coracao crescendo emocao
    \\💓|heartbeat|beating heart|coracao pulsante amor batendo coracao emocao pulsante s2
    \\💞|revolving_hearts|revolving hearts|coracoes girando adoravel amor bonitinho coracao coracoes emocao
    \\💕|two_hearts|two hearts|dois coracoes amor aniversario casal coracao dois emocao
    \\💟|heart_decoration|heart decoration|coracao decorativo amor coracao decoracao decorativo roxo s2
    \\❣️|heavy_heart_exclamation|heart exclamation|exclamacao de coracao amor coracao exclamacao pontuacao s2 sinal
    \\💔|broken_heart|broken heart|coracao partido amorosa coracao decepcao desilusao emocao partido
    \\❤️‍🔥|heart_on_fire|heart on fire|coracao em chamas amor chamas coracao coracao sagrado fogo
    \\❤️‍🩹|mending_heart|mending heart|coracao remendado bem bom curando mais saudavel melhorando
    \\❤️|heart|love red heart|coracao vermelho amor coracao s2
    \\🩷|pink_heart|pink heart|coracao rosa adoravel adorei amo voce amor coracao curtir
    \\🧡|orange_heart|orange heart|coracao laranja coracao emocao laranja s2
    \\💛|yellow_heart|yellow heart|coracao amarelo amarelo amor coracao emocao love s2
    \\💚|green_heart|green heart|coracao verde coracao emocao s2 verde
    \\💙|blue_heart|blue heart|coracao azul azul coracao emocao s2
    \\🩵|light_blue_heart|light blue heart|coracao azul-claro adorar adorei amo voce amor coracao emocao
    \\💜|purple_heart|purple heart|coracao roxo coracao coracao lilas emocao roxo s2
    \\🤎|brown_heart|brown heart|coracao marrom coracao marrom s2
    \\🖤|black_heart|black heart|coracao preto coracao negro preto s2
    \\🩶|grey_heart|grey heart|coracao cinza adorar adorei amo voce amor coracao emocao
    \\🤍|white_heart|white heart|coracao branco branco coracao s2
    \\💋|kiss|lipstick kiss mark|marca de beijo beijo labios romance
    \\💯|100|score perfect hundred points|cem pontos 100 cem certamente certeza conte comigo pontos
    \\💢|anger|angry anger symbol|simbolo de raiva com raiva emocao engracado raiva
    \\🫯|fight_cloud|fight cloud|nuvem de briga briga debate desacordo discussao luta tumulto
    \\💥|boom|collision explode|colisao emocao engracado explosao simbolo de colisao
    \\💫|dizzy|star dizzy|zonzo brilhante emocao engracado estrelas olhando para as estrelas
    \\💦|sweat_drops|water workout sweat droplets|pingos de suor borrifo com suor emocao engracado splash
    \\💨|dash|wind blow fast dashing away|rapidez correr corrida emocao engracado fugir
    \\🕳️|hole|hole|buraco buraco no chao
    \\💬|speech_balloon|comment speech balloon|balao de dialogo balao balao de conversa dialogo engracado
    \\👁️‍🗨️|eye_speech_bubble|eye in speech bubble|olho no balao de dialogo balao de dialogo olho testemunha
    \\🗨️|left_speech_bubble|left speech bubble|balao de dialogo a esquerda azul balao conversa dialogo esquerda
    \\🗯️|right_anger_bubble|right anger bubble|balao de raiva a direita balao briga conversa dialogo direita discurso
    \\💭|thought_balloon|thinking thought balloon|balao de pensamento balao engracado ideia invencao inventando
    \\💤|zzz|sleeping zzz|zzz boa noite cansada cansado com sono dormindo dormir
    \\👋|wave|goodbye waving hand|mao acenando acenando aceno ate mais esta ai? flw mao
    \\🤚|raised_back_of_hand|raised back of hand|dorso da mao levantado dorso levantada levantado mao para tudo pare
    \\🖐️|raised_hand_with_fingers_splayed|hand with fingers splayed|mao aberta com os dedos separados 5 aberta cinco dedos mao palma
    \\✋|hand|raised_hand highfive stop raised hand|mao levantada 5 cinco erguida high five levantada mao
    \\🖖|vulcan_salute|prosper spock vulcan salute|saudacao vulcana dedos jornada nas estrelas mao saudacao saudacao star trek
    \\🫱|rightwards_hand|rightwards hand|mao para a direita apertar aperto direita mao pegar segurar
    \\🫲|leftwards_hand|leftwards hand|mao para a esquerda apertar esquerda mao pegar segurar
    \\🫳|palm_down_hand|palm down hand|mao com a palma para baixo cair derrubar descartar mao pegar
    \\🫴|palm_up_hand|palm up hand|mao com a palma para cima acenar levantar mao oferecer pegar
    \\🫷|leftwards_pushing_hand|leftwards pushing hand|mao empurrando para a esquerda bate aqui bloquear empurrar esperar esquerda high five
    \\🫸|rightwards_pushing_hand|rightwards pushing hand|mao empurrando para a direita bate aqui bloquear direita empurrar esperar high five
    \\👌|ok_hand|ok hand|sinal de ok beliscar certo concordo mao ok otimo
    \\🤌|pinched_fingers|pinched fingers|dedos comprimidos beliscado coxinha dedos gesto de mao ha interrogacao
    \\🤏|pinching_hand|pinching hand|mao beliscando beliscar mao pequena quantidade pequeno pouco pouquinho
    \\✌️|v|victory peace victory hand|mao em v de vitoria beleza mao paz sim v de vitoria vitoria
    \\🤞|crossed_fingers|luck hopeful crossed fingers|dedos cruzados boa sorte cruzados dedos mao sorte torcendo
    \\🫰|hand_with_index_finger_and_thumb_crossed|hand with index finger and thumb crossed|mao com dedo indicador e polegar cruzados <3 amor army caro coracao dinheiro
    \\🤟|love_you_gesture|love-you gesture|gesto de "te amo" amor gesto mao te amo
    \\🤘|metal|sign of the horns|saudacao do rock chifres dedos mao metal rock
    \\🤙|call_me_hand|call me hand|sinal "me liga" legal ligar mao me liga
    \\👈|point_left|backhand index pointing left|dorso da mao com indicador apontando para a esquerda costas dedo dorso esquerda indicador mao
    \\👉|point_right|backhand index pointing right|dorso da mao com indicador apontando para a direita apontar costas dedo direita dorso indicador
    \\👆|point_up_2|backhand index pointing up|dorso da mao com indicador apontando para cima cima costas dedo dedo para cima dorso indicador
    \\🖕|middle_finger|fu middle finger|dedo do meio dedo gesto ofensivo mao
    \\👇|point_down|backhand index pointing down|dorso da mao com indicador apontando para baixo abaixo costas da mao dedo dedo apontado para baixo dedo indicador dedo para baixo
    \\☝️|point_up|index pointing up|indicador apontando para cima dedo dedo apontando para cima eu indicador mao
    \\🫵|index_pointing_at_the_viewer|index pointing at the viewer|indicador apontando para o visualizador ai apontar cutucar dedo indicador
    \\👍|thumbsup|+1 approve ok thumbs up|polegar para cima beleza cima concordo dedao joia mao
    \\👎|thumbsdown|-1 disapprove bury thumbs down|polegar para baixo dedao dedao para baixo desaprovacao desaprovado mao nao
    \\🫹|leftwards_thumb_sign|leftwards thumb sign|sinal de polegar para a esquerda apontar aquele aquilo esquerda essa esse
    \\🫺|rightwards_thumb_sign|rightwards thumb sign|sinal de polegar para a direita apontar aquele aquilo direita essa esse
    \\✊|fist_raised|fist power raised fist|punho levantado pedra punho punho erguido solidariedade
    \\👊|fist_oncoming|facepunch punch attack oncoming fist|soco beleza fechado forca mao punho
    \\🤛|fist_left|left-facing fist|punho esquerdo esquerdo fechada mao punho soco
    \\🤜|fist_right|right-facing fist|punho direito direito punho soco
    \\👏|clap|praise applause clapping hands|maos aplaudindo aplauso bom trabalho maos palmas parabens
    \\🙌|raised_hands|hooray raising hands|maos para cima ambas as maos comemoracao levantando ambas as maos para comemorar viva
    \\🫶|heart_hands|love heart hands|maos de coracao <3 amei amo voce amor coracao mao
    \\👐|open_hands|open hands|maos abertas abertas mao sinal sinal de maos abertas
    \\🤲|palms_up_together|palms up together|palmas unidas para cima cima devocao juntas oracao palmas unidas
    \\🤝|handshake|deal handshake|aperto de maos aperto combinado cumprimento maos
    \\🙏|pray|please hope wish folded hands|maos juntas gesto mao reza rezando rezar
    \\✍️|writing_hand|writing hand|escrevendo a mao caneta escrevendo mao
    \\💅|nail_care|beauty manicure nail polish|esmalte de unha cosmeticos esmalte manicure mao unhas
    \\🤳|selfie|selfie|selfie camera celular foto smartphone
    \\💪|muscle|flex bicep strong workout flexed biceps|biceps academia contraido engracado forte musculacao
    \\🦾|mechanical_arm|mechanical arm|braco mecanico acessibilidade protese
    \\🦿|mechanical_leg|mechanical leg|perna mecanica acessibilidade protese
    \\🦵|leg|leg|perna chute joelho membro pe perna dobrada
    \\🦶|foot|foot|pe calcanhar chutar chute pisao pisar
    \\👂|ear|hear sound listen ear|orelha corpo escutar ouvido
    \\🦻|ear_with_hearing_aid|ear with hearing aid|ouvido com aparelho auditivo acessibilidade aparelho auditivo deficiencia auditiva surda surdo
    \\👃|nose|smell nose|nariz cheirar cheiro corpo odor rosto
    \\🧠|brain|brain|cerebro inteligencia inteligente
    \\🫀|anatomical_heart|anatomical heart|coracao humano anatomia batimento batimento cardiaco cardiologia centro coracao
    \\🫁|lungs|lungs|pulmoes anatomia espiracao exalacao inalacao orgao pulmao
    \\🦷|tooth|tooth|dente branco dentista
    \\🦴|bone|bone|osso cachorro esqueleto
    \\👀|eyes|look see watch eyes|olhos olhando olho rosto to de olho
    \\👁️|eye|eye|olho parte do corpo rosto
    \\👅|tongue|taste tongue|lingua corpo rosto
    \\👄|lips|kiss mouth|boca batom beijo corpo labios rosto
    \\🫦|biting_lip|biting lip|mordendo o labio ansioso batom beijo flertar labios medo
    \\👶|baby|child newborn baby|bebe bebezinho gravida nenem pessoas recem-nascido
    \\🧒|child|child|crianca filho jovem neto pequeno
    \\👦|boy|child boy|menino garoto guri jovem loiro pessoas
    \\👧|girl|child girl|menina filha garota menininha neta pessoas
    \\🧑|adult|person|pessoa adulta adulto
    \\👱|blond_haired_person|person: blond hair|pessoa: cabelo louro cabelo loiro louro pessoa pessoa loira pessoa loura
    \\👨|man|mustache father dad man|homem adulto amigo irmao marido namorado
    \\🧔|bearded_person|person: beard|homem: barba barba barbudo homem pessoa
    \\🧔‍♂️|man_beard|man: beard|homem: barbudo barba homem homem: barba
    \\🧔‍♀️|woman_beard|woman: beard|mulher: barba barba mulher
    \\👨‍🦰|red_haired_man|man: red hair|
    \\👨‍🦱|curly_haired_man|man: curly hair|
    \\👨‍🦳|white_haired_man|man: white hair|
    \\👨‍🦲|bald_man|man: bald|
    \\👩|woman|girls woman|mulher adulta garota guria loira menina mina
    \\👩‍🦰|red_haired_woman|woman: red hair|
    \\🧑‍🦰|person_red_hair|person: red hair|
    \\👩‍🦱|curly_haired_woman|woman: curly hair|
    \\🧑‍🦱|person_curly_hair|person: curly hair|
    \\👩‍🦳|white_haired_woman|woman: white hair|
    \\🧑‍🦳|person_white_hair|person: white hair|
    \\👩‍🦲|bald_woman|woman: bald|
    \\🧑‍🦲|person_bald|person: bald|
    \\👱‍♀️|blond_haired_woman|blonde_woman woman: blond hair|mulher: cabelo loiro garota guria loira loura menina mulher
    \\👱‍♂️|blond_haired_man|man: blond hair|homem: cabelo loiro cabelo homem loiro louro
    \\🧓|older_adult|older person|idoso adulto avo sabio velho vovo
    \\👴|older_man|old man|homem idoso adulto avo careca homem idoso pessoas
    \\👵|older_woman|old woman|idosa adulta mulher pessoas velhinha vovo
    \\🙍|frowning_person|person frowning|franzindo a sobrancelha brava bravo chateada chateado franzindo a testa
    \\🙍‍♂️|frowning_man|man frowning|homem franzindo a sobrancelha carrancudo chateado desconfiado gesto homem
    \\🙍‍♀️|frowning_woman|woman frowning|mulher franzindo a sobrancelha carrancuda desconfiada mulher
    \\🙎|pouting_face|person pouting|pessoa fazendo bico beicinho beico careta chateada chateado emburrada
    \\🙎‍♂️|pouting_man|man pouting|homem fazendo bico apontando bico cara feia gesto homem
    \\🙎‍♀️|pouting_woman|woman pouting|mulher fazendo bico bico cara feia mulher
    \\🙅|no_good|stop halt denied person gesturing no|pessoa fazendo gesto de “nao” de jeito nenhum gesto mao nao proibido sem chance
    \\🙅‍♂️|no_good_man|ng_man stop halt denied man gesturing no|homem fazendo gesto de “nao” gesto homem mao menino nao
    \\🙅‍♀️|no_good_woman|ng_woman stop halt denied woman gesturing no|mulher fazendo gesto de “nao” gesto mao mulher proibido
    \\🙆|ok_person|person gesturing ok|pessoa fazendo gesto de “ok” exercicio gesto gesto para ok mao maos para cima ok
    \\🙆‍♂️|ok_man|man gesturing ok|homem fazendo gesto de “ok” cabeca exercicio gesto homem mao menino
    \\🙆‍♀️|ok_woman|woman gesturing ok|mulher fazendo gesto de “ok” gesto mao mulher ok
    \\💁|tipping_hand_person|information_desk_person person tipping hand|pessoa com a palma virada para cima ajuda diva divo fala serio fofoca informacoes
    \\💁‍♂️|tipping_hand_man|sassy_man information man tipping hand|homem com a palma virada para cima ajuda fofoca garoto gorjeta guri homem
    \\💁‍♀️|tipping_hand_woman|sassy_woman information woman tipping hand|mulher com a palma virada para cima mulher
    \\🙋|raising_hand|person raising hand|pessoa levantando a mao duvida eu eu sei feliz gesto levantando a mao
    \\🙋‍♂️|raising_hand_man|man raising hand|homem levantando a mao eu eu sei gesto homem levantando a mao
    \\🙋‍♀️|raising_hand_woman|woman raising hand|mulher levantando a mao gesto mao mulher pedir a palavra
    \\🧏|deaf_person|deaf person|pessoa surda acessibilidade audicao orelha surda surdo
    \\🧏‍♂️|deaf_man|deaf man|homem surdo homem surdo
    \\🧏‍♀️|deaf_woman|deaf woman|mulher surda mulher surda
    \\🙇|bow|respect thanks person bowing|pessoa fazendo reverencia arrependimento desculpa desculpe gesto meditacao perdao
    \\🙇‍♂️|bowing_man|respect thanks man bowing|homem fazendo reverencia desculpas gesto homem homem pedindo desculpas respeito
    \\🙇‍♀️|bowing_woman|respect thanks woman bowing|mulher fazendo reverencia desculpas desculpe gesto meditacao meditar mulher
    \\🤦|facepalm|person facepalming|pessoa decepcionada como assim decepcao decepcionada decepcionado desapontamento descrenca
    \\🤦‍♂️|man_facepalming|man facepalming|homem decepcionado como assim decepcao decepcionado desapontamento homem inacreditavel
    \\🤦‍♀️|woman_facepalming|woman facepalming|mulher decepcionada como assim decepcao decepcionada desapontamento inacreditavel meu deus
    \\🤷|shrug|person shrugging|pessoa dando de ombros dar de ombros duvida ignorancia indiferenca nao sei ombros
    \\🤷‍♂️|man_shrugging|man shrugging|homem dando de ombros dar de ombros duvida homem indiferenca menino
    \\🤷‍♀️|woman_shrugging|woman shrugging|mulher dando de ombros dar de ombros duvida garota indiferenca menina mulher
    \\🧑‍⚕️|health_worker|health worker|profissional de saude cuidados de saude enfermeira medico terapeuta
    \\👨‍⚕️|man_health_worker|doctor nurse man health worker|homem profissional da saude doutor enfermeiro homem medico saude
    \\👩‍⚕️|woman_health_worker|doctor nurse woman health worker|mulher profissional da saude doutora enfermeira garota guria medica menina
    \\🧑‍🎓|student|student|aluno estudante graduando
    \\👨‍🎓|man_student|graduation man student|estudante aluno colando grau formando graduacao homem
    \\👩‍🎓|woman_student|graduation woman student|aluna estudante formanda mulher
    \\🧑‍🏫|teacher|teacher|professora na escola instrutora professora
    \\👨‍🏫|man_teacher|school professor man teacher|professor educador homem instrutor mestre
    \\👩‍🏫|woman_teacher|school professor woman teacher|professora instrutora mestra mulher
    \\🧑‍⚖️|judge|judge|juiz no tribunal balanca juiz
    \\👨‍⚖️|man_judge|justice man judge|juiz balanca homem justica
    \\👩‍⚖️|woman_judge|justice woman judge|juiza balanca justica mulher
    \\🧑‍🌾|farmer|farmer|agricultor jardineiro rancheiro
    \\👨‍🌾|man_farmer|man farmer|fazendeiro agricultor homem jardineiro
    \\👩‍🌾|woman_farmer|woman farmer|fazendeira agricultora jardineira mulher
    \\🧑‍🍳|cook|cook|chef de cozinha chef cozinheiro
    \\👨‍🍳|man_cook|chef man cook|cozinheiro chef homem restaurante
    \\👩‍🍳|woman_cook|chef woman cook|cozinheira chef mulher
    \\🧑‍🔧|mechanic|mechanic|mecanico trabalhando eletricista encanador mecanico prestador de servico
    \\👨‍🔧|man_mechanic|man mechanic|mecanico eletricista encanador homem prestador de servicos
    \\👩‍🔧|woman_mechanic|woman mechanic|mecanica eletricista encanadora mulher prestadora de servicos
    \\🧑‍🏭|factory_worker|factory worker|funcionario de fabrica fabrica industrial montagem trabalhador
    \\👨‍🏭|man_factory_worker|man factory worker|operario fabrica homem industria metalurgico trabalhador
    \\👩‍🏭|woman_factory_worker|woman factory worker|operaria fabrica industria mulher trabalhadora
    \\🧑‍💼|office_worker|office worker|trabalhador de escritorio arquiteto colarinho branco gerente negocios
    \\👨‍💼|man_office_worker|business man office worker|funcionario de escritorio arquiteto colarinho branco empresario escritorio gerente
    \\👩‍💼|woman_office_worker|business woman office worker|funcionaria de escritorio arquiteta branco colarinho empresaria escritorio funcionaria
    \\🧑‍🔬|scientist|scientist|cientista biologo engenheiro fisico quimico
    \\👨‍🔬|man_scientist|research man scientist|cientista homem biologo fisico homem professor quimico
    \\👩‍🔬|woman_scientist|research woman scientist|cientista mulher biologa cientista fisica mulher professora quimica
    \\🧑‍💻|technologist|technologist|programador desenvolvedor inventor software tecnologo
    \\👨‍💻|man_technologist|coder man technologist|tecnologo codificador computador criador desenvolvedor homem inventor
    \\👩‍💻|woman_technologist|coder woman technologist|tecnologa codificadora computador criadora desenvolvedora inventora mulher
    \\🧑‍🎤|singer|singer|cantor ator entretenimento estrela rock
    \\👨‍🎤|man_singer|rockstar man singer|cantor homem artista ator cantor homem pop rock
    \\👩‍🎤|woman_singer|rockstar woman singer|cantora artista atriz mulher pop rock
    \\🧑‍🎨|artist|artist|artista paleta
    \\👨‍🎨|man_artist|painter man artist|artista plastico artista homem pintor pintura plastico quadros
    \\👩‍🎨|woman_artist|painter woman artist|artista plastica artista mulher pintura
    \\🧑‍✈️|pilot|pilot|piloto aviao
    \\👨‍✈️|man_pilot|man pilot|piloto de aviao homem aviao homem piloto
    \\👩‍✈️|woman_pilot|woman pilot|piloto de aviao mulher aviao garota guria mulher piloto
    \\🧑‍🚀|astronaut|astronaut|astronauta foguete
    \\👨‍🚀|man_astronaut|space man astronaut|astronauta homem espaco foguete homem
    \\👩‍🚀|woman_astronaut|space woman astronaut|astronauta mulher astronauta espaco foguete mulher
    \\🧑‍🚒|firefighter|firefighter|bombeiro caminhao de bombeiros
    \\👨‍🚒|man_firefighter|man firefighter|bombeiro homem bombeiro caminhao corpo de bombeiros fogo homem incendio
    \\👩‍🚒|woman_firefighter|woman firefighter|bombeira caminhao corpo de bombeiros fogo incendio mulher
    \\👮|police_officer|cop law police officer|policial autoridade multar pessoa policia prender
    \\👮‍♂️|policeman|law cop man police officer|policial homem homem policia policial tira
    \\👮‍♀️|policewoman|law cop woman police officer|policial mulher autoridade mulher multar policia policial prender
    \\🕵️|detective|sleuth detective|detetive espiao investigador rosto rosto com lupa
    \\🕵️‍♂️|male_detective|sleuth man detective|detetive homem espiao homem investigador
    \\🕵️‍♀️|female_detective|sleuth woman detective|detetive mulher detetive espia espionar investigadora investigar mulher
    \\💂|guard|guard|guarda londres palacio pessoas seguranca
    \\💂‍♂️|guardsman|man guard|guarda homem guarda homem seguranca
    \\💂‍♀️|guardswoman|woman guard|guarda mulher buckingham guarda londres mulher palacio realeza
    \\🥷|ninja|ninja|ninja assassino furtividade guerra habilidades luta lutador
    \\👷|construction_worker|helmet construction worker|trabalhador de construcao civil capacete chapeu construcao construcao civil construir pessoa
    \\👷‍♂️|construction_worker_man|helmet man construction worker|pedreiro construcao homem operario
    \\👷‍♀️|construction_worker_woman|helmet woman construction worker|pedreira capacete construcao contrucao mulher operaria operario
    \\🫅|person_with_crown|person with crown|pessoa com coroa coroa monarca nobre pessoa princesa
    \\🤴|prince|crown royal prince|principe realeza rei
    \\👸|princess|crown royal princess|princesa conto coroa fadas fantasia loira menina
    \\👳|person_with_turban|person wearing turban|pessoa com turbante pessoa turbante
    \\👳‍♂️|man_with_turban|man wearing turban|homem com turbante homem turbante
    \\👳‍♀️|woman_with_turban|woman wearing turban|mulher com turbante mulher turbante
    \\👲|man_with_gua_pi_mao|person with skullcap|homem de bone chapeu chines gua pi mao guapimao homem com gua pi mao pessoas
    \\🧕|woman_with_headscarf|hijab woman with headscarf|mulher com veu cabeca hijab lenco mulher
    \\🤵|person_in_tuxedo|groom marriage wedding person in tuxedo|pessoa de smoking festa gala homem homem de smoking noivo
    \\🤵‍♂️|man_in_tuxedo|man in tuxedo|homem de smoking homem smoking
    \\🤵‍♀️|woman_in_tuxedo|woman in tuxedo|mulher de smoking mulher smoking
    \\👰|person_with_veil|marriage wedding person with veil|pessoa com veu casamento noiva noiva com veu pessoas veu
    \\👰‍♂️|man_with_veil|man with veil|noivo com veu noivo veu
    \\👰‍♀️|woman_with_veil|bride_with_veil woman with veil|noiva com veu noiva veu
    \\🤰|pregnant_woman|pregnant woman|gravida estou gravida gravidez mulher
    \\🫃|pregnant_man|pregnant man|homem gravido barriga cheia cheio comi demais excesso de peso gravidez
    \\🫄|pregnant_person|pregnant person|pessoa gravida barriga cheia cheio comi demais excesso excesso de peso
    \\🤱|breast_feeding|nursing breast-feeding|amamentando amamentacao bebe leite mae materno nenem
    \\👩‍🍼|woman_feeding_baby|woman feeding baby|mulher alimentando bebe alimentando amamentacao amamentando amor bebe mae
    \\👨‍🍼|man_feeding_baby|man feeding baby|homem alimentando bebe alimentando amamentacao amamentando amor bebe homem
    \\🧑‍🍼|person_feeding_baby|person feeding baby|pessoa alimentando bebe alimentando amamentacao amamentar bebe homem mae
    \\👼|angel|baby angel|bebe anjo anjo bebe conto fadas rosto
    \\🎅|santa|christmas santa claus|papai noel comemoracao festas natal noel papai
    \\🤶|mrs_claus|santa mrs. claus|mamae noel comemoracao mamae natal noel vovo
    \\🧑‍🎄|mx_claus|mx claus|noel chapeu feliz festas gorro mamae natal
    \\🦸|superhero|superhero|super-heroi bem boa bom heroi heroina
    \\🦸‍♂️|superhero_man|man superhero|homem super-heroi bom heroi homem superpoder
    \\🦸‍♀️|superhero_woman|woman superhero|super-heroina boa heroi heroina mulher superpoder
    \\🦹|supervillain|supervillain|supervilao bandido criminoso mal malvado mau superpoder
    \\🦹‍♂️|supervillain_man|man supervillain|homem supervilao criminoso homem mal superpoder vilao
    \\🦹‍♀️|supervillain_woman|woman supervillain|supervila criminosa ma mulher superpoder vila
    \\🧙|mage|wizard mage|mago bruxa fantasia feiticeira feiticeiro feitico maga
    \\🧙‍♂️|mage_man|wizard man mage|homem mago feiticeiro mago
    \\🧙‍♀️|mage_woman|wizard woman mage|maga bruxa feiticeira
    \\🧚|fairy|fairy|fada asas conto encantado fantasia ser
    \\🧚‍♂️|fairy_man|man fairy|homem fada fada
    \\🧚‍♀️|fairy_woman|woman fairy|mulher fada fada
    \\🧛|vampire|vampire|vampiro assustador bruxas dia dracula fantasia halloween
    \\🧛‍♂️|vampire_man|man vampire|homem vampiro dracula vampiro
    \\🧛‍♀️|vampire_woman|woman vampire|mulher vampira vampira
    \\🧜|merperson|merperson|pessoa sereia canto cauda contos criatura fada fundo
    \\🧜‍♂️|merman|merman|sereio tritao
    \\🧜‍♀️|mermaid|mermaid|sereia
    \\🧝|elf|elf|elfo duende fantasia legolas magia magico
    \\🧝‍♂️|elf_man|man elf|elfo homem duende homem elfo
    \\🧝‍♀️|elf_woman|woman elf|elfa duende mulher
    \\🧞|genie|genie|genio desejos fantasia lampada magica mistico
    \\🧞‍♂️|genie_man|man genie|homem genio
    \\🧞‍♀️|genie_woman|woman genie|mulher genio
    \\🧟|zombie|zombie|zumbi apocalipse assustador bruxas dia halloween morto-vivo
    \\🧟‍♂️|zombie_man|man zombie|homem zumbi cazumbi
    \\🧟‍♀️|zombie_woman|woman zombie|mulher zumbi cazumbi
    \\🧌|troll|troll|troll conto fadas fantasia gigante monstro ogro
    \\🫈|hairy_creature|hairy creature|criatura peluda criptido eua floresta gigante pe grande pe‐grande
    \\💆|massage|spa person getting massage|pessoa recebendo massagem facial dor de cabeca massagem massagem facial pele relaxar
    \\💆‍♂️|massage_man|spa man getting massage|homem recebendo massagem facial acalmar dor de cabeca homem massagem menino
    \\💆‍♀️|massage_woman|spa woman getting massage|mulher recebendo massagem facial massagem mulher relaxamento
    \\💇|haircut|beauty person getting haircut|pessoa cortando o cabelo beleza cortando o cabelo corte de cabelo pessoa salao
    \\💇‍♂️|haircut_man|man getting haircut|homem cortando o cabelo barbeiro beleza cabelo corte homem menino
    \\💇‍♀️|haircut_woman|woman getting haircut|mulher cortando o cabelo corte de cabelo mulher salao de beleza
    \\🚶|walking|person walking|pessoa andando andar caminhada caminhar passo pedestre perambulando
    \\🚶‍♂️|walking_man|man walking|homem andando andar caminhar homem caminhando
    \\🚶‍♀️|walking_woman|woman walking|mulher andando andando andar caminhada caminhando caminhar mulher
    \\🚶‍➡️|person_walking_facing_right|person walking facing right|
    \\🚶‍♀️‍➡️|woman_walking_facing_right|woman walking facing right|
    \\🚶‍♂️‍➡️|man_walking_facing_right|man walking facing right|
    \\🧍|standing_person|person standing|pessoa em pe de pe
    \\🧍‍♂️|standing_man|man standing|homem em pe em pe homem
    \\🧍‍♀️|standing_woman|woman standing|mulher em pe em pe mulher
    \\🧎|kneeling_person|person kneeling|pessoa ajoelhando ajoelhado ajoelhar joelhos pedir pessoa por favor
    \\🧎‍♂️|kneeling_man|man kneeling|homem ajoelhando ajoelhado homem
    \\🧎‍♀️|kneeling_woman|woman kneeling|mulher ajoelhando ajoelhada mulher
    \\🧎‍➡️|person_kneeling_facing_right|person kneeling facing right|
    \\🧎‍♀️‍➡️|woman_kneeling_facing_right|woman kneeling facing right|
    \\🧎‍♂️‍➡️|man_kneeling_facing_right|man kneeling facing right|
    \\🧑‍🦯|person_with_probing_cane|person with white cane|pessoa com bengala para cego acessibilidade cego
    \\🧑‍🦯‍➡️|person_with_white_cane_facing_right|person with white cane facing right|
    \\👨‍🦯|man_with_probing_cane|man with white cane|homem com bengala para cego accessibilidade cego homem
    \\👨‍🦯‍➡️|man_with_white_cane_facing_right|man with white cane facing right|
    \\👩‍🦯|woman_with_probing_cane|woman with white cane|mulher com bengala para cego accessibilidade cega deficiencia visual mulher
    \\👩‍🦯‍➡️|woman_with_white_cane_facing_right|woman with white cane facing right|
    \\🧑‍🦼|person_in_motorized_wheelchair|person in motorized wheelchair|pessoa em cadeira de rodas motorizada acessibilidade cadeira de rodas
    \\🧑‍🦼‍➡️|person_in_motorized_wheelchair_facing_right|person in motorized wheelchair facing right|
    \\👨‍🦼|man_in_motorized_wheelchair|man in motorized wheelchair|homem em cadeira de rodas motorizada acessibilidade cadeira de rodas homem
    \\👨‍🦼‍➡️|man_in_motorized_wheelchair_facing_right|man in motorized wheelchair facing right|
    \\👩‍🦼|woman_in_motorized_wheelchair|woman in motorized wheelchair|mulher em cadeira de rodas motorizada acessibilidade cadeira de rodas mulher
    \\👩‍🦼‍➡️|woman_in_motorized_wheelchair_facing_right|woman in motorized wheelchair facing right|
    \\🧑‍🦽|person_in_manual_wheelchair|person in manual wheelchair|pessoa em cadeira de rodas manual acessibilidade cadeira de rodas
    \\🧑‍🦽‍➡️|person_in_manual_wheelchair_facing_right|person in manual wheelchair facing right|
    \\👨‍🦽|man_in_manual_wheelchair|man in manual wheelchair|homem em cadeira de rodas manual acessibilidade cadeira de rodas homem
    \\👨‍🦽‍➡️|man_in_manual_wheelchair_facing_right|man in manual wheelchair facing right|
    \\👩‍🦽|woman_in_manual_wheelchair|woman in manual wheelchair|mulher em cadeira de rodas manual acessibilidade cadeira de rodas mulher
    \\👩‍🦽‍➡️|woman_in_manual_wheelchair_facing_right|woman in manual wheelchair facing right|
    \\🏃|runner|running exercise workout marathon person running|pessoa correndo correndo correr corrida esporte maratona maratonista
    \\🏃‍♂️|running_man|exercise workout marathon man running|homem correndo corrida esporte homem maratona
    \\🏃‍♀️|running_woman|exercise workout marathon woman running|mulher correndo corredora correndo corrida esporte garota guria
    \\🏃‍➡️|person_running_facing_right|person running facing right|
    \\🏃‍♀️‍➡️|woman_running_facing_right|woman running facing right|
    \\🏃‍♂️‍➡️|man_running_facing_right|man running facing right|
    \\🧑‍🩰|ballet_dancer|ballet dancer|bailarina bailarino bale ballet dancarina dancarino
    \\💃|woman_dancing|dancer dress woman dancing|mulher dancando bailarina danca dancando flamenco mulher pessoas
    \\🕺|man_dancing|dancer man dancing|homem dancando dancando homem
    \\🕴️|business_suit_levitating|person in suit levitating|homem de terno levitando homem homem de terno terno
    \\👯|dancers|bunny people with bunny ears|pessoas com orelhas de coelho amigas coelho dancar dancarinas festa gemeas
    \\👯‍♂️|dancing_men|bunny men with bunny ears|homens com orelhas de coelho coelho dancarino festa homem meninos orelhas
    \\👯‍♀️|dancing_women|bunny women with bunny ears|mulheres com orelhas de coelho dancarinas festa mulheres orelha de coelho
    \\🧖|sauna_person|steamy person in steamy room|pessoa na sauna banho homem mulher pessoa relaxar sauna
    \\🧖‍♂️|sauna_man|steamy man in steamy room|homem na sauna sauna
    \\🧖‍♀️|sauna_woman|steamy woman in steamy room|mulher na sauna sauna
    \\🧗|climbing|bouldering person climbing|pessoa escalando alpinista escalada escalando escalar esporte montanha
    \\🧗‍♂️|climbing_man|bouldering man climbing|homem escalando escalar
    \\🧗‍♀️|climbing_woman|bouldering woman climbing|mulher escalando escalar
    \\🤺|person_fencing|person fencing|esgrimista esgrima espada esporte pessoa
    \\🏇|horse_racing|horse racing|corrida de cavalos cavalo corrida esporte jockey joquei
    \\⛷️|skier|skier|esquiador esporte esqui frio neve
    \\🏂|snowboarder|snowboarder|praticante de snowboard esporte inverno neve ski snowboard
    \\🏌️|golfing|person golfing|golfista bola esporte golf golfe jogando
    \\🏌️‍♂️|golfing_man|man golfing|homem golfista golfe homem homem jogando golfe
    \\🏌️‍♀️|golfing_woman|woman golfing|mulher golfista bola esporte garota golf golfe golfista
    \\🏄|surfer|person surfing|surfista esporte onda ondas pessoa praia prancha
    \\🏄‍♂️|surfing_man|man surfing|homem surfista homem surfando
    \\🏄‍♀️|surfing_woman|woman surfing|mulher surfista esporte garota guria mar menina mulher
    \\🚣|rowboat|person rowing boat|pessoa remando barco bote canoa mar oceano pessoa
    \\🚣‍♂️|rowing_man|man rowing boat|homem remando esporte homem remador remo
    \\🚣‍♀️|rowing_woman|woman rowing boat|mulher remando barco caiaque canoa esporte garota menina
    \\🏊|swimmer|person swimming|pessoa nadando esporte nadar natacao olimpiada triatlo
    \\🏊‍♂️|swimming_man|man swimming|homem nadando homem nadar natacao
    \\🏊‍♀️|swimming_woman|woman swimming|mulher nadando esporte homem nadadora nado natacao olimpiada
    \\⛹️|bouncing_ball_person|basketball person bouncing ball|pessoa jogando basquete arremesso atleta basquete bater bola bola cesta
    \\⛹️‍♂️|bouncing_ball_man|basketball_man man bouncing ball|homem jogando basquete basquete bola esporte homem
    \\⛹️‍♀️|bouncing_ball_woman|basketball_woman woman bouncing ball|mulher jogando basquete basketball basquete bola esporte garota jogadora
    \\🏋️|weight_lifting|gym workout person lifting weights|pessoa levantando peso bodybuilder esporte fisiculturista forca levantar peso
    \\🏋️‍♂️|weight_lifting_man|gym workout man lifting weights|homem levantando peso esporte forca homem peso
    \\🏋️‍♀️|weight_lifting_woman|gym workout woman lifting weights|mulher levantando peso esporte forca garota guria levantadora de peso levantar
    \\🚴|bicyclist|person biking|ciclista bicicleta bike ciclismo esporte pedalar
    \\🚴‍♂️|biking_man|man biking|homem ciclista bicicleta esporte homem passeio
    \\🚴‍♀️|biking_woman|woman biking|mulher ciclista bicicleta bike ciclismo ciclista esporte garota
    \\🚵|mountain_bicyclist|person mountain biking|pessoa fazendo mountain bike bicicleta ciclismo ciclista esporte montanha mountain bike
    \\🚵‍♂️|mountain_biking_man|man mountain biking|homem fazendo mountain bike bicicleta ciclista mountain bike
    \\🚵‍♀️|mountain_biking_woman|woman mountain biking|mulher fazendo mountain bike bicicleta bike ciclista esporte garota guria
    \\🤸|cartwheeling|person cartwheeling|pessoa fazendo estrela animada animado esporte estrela estrelinha feliz
    \\🤸‍♂️|man_cartwheeling|man cartwheeling|homem fazendo estrela animado esporte estrela estrelinha feliz ginastica
    \\🤸‍♀️|woman_cartwheeling|woman cartwheeling|mulher fazendo estrela animada esporte estrela feliz ginasta ginastica
    \\🤼|wrestling|people wrestling|pessoas lutando combate esporte greco-romana livre luta lutador
    \\🤼‍♂️|men_wrestling|men wrestling|homens lutando combate esporte greco-romana homem livre luta
    \\🤼‍♀️|women_wrestling|women wrestling|mulheres lutando combate esporte greco-romana livre luta lutadora
    \\🤽|water_polo|person playing water polo|pessoa jogando polo aquatico aquatico competicao esporte pessoa piscina polo
    \\🤽‍♂️|man_playing_water_polo|man playing water polo|homem jogando polo aquatico aquatico esporte homem jogador jogando piscina
    \\🤽‍♀️|woman_playing_water_polo|woman playing water polo|mulher jogando polo aquatico aquatico esporte jogadora menina mulher piscina
    \\🤾|handball_person|person playing handball|handebol atleta bola esporte gol handball
    \\🤾‍♂️|man_playing_handball|man playing handball|jogador de handebol bola esporte handball handebol homem jogador
    \\🤾‍♀️|woman_playing_handball|woman playing handball|jogadora de handebol bola esporte gol handball handebol jogadora
    \\🤹|juggling_person|person juggling|malabarista equilibrio habilidade malabares malabarismo multitarefa
    \\🤹‍♂️|man_juggling|man juggling|homem malabarista equilibrio habilidade homem malabares malabarismo multitarefa
    \\🤹‍♀️|woman_juggling|woman juggling|mulher malabarista equilibrio habilidade malabarismo malabarista mulher multitarefa
    \\🧘|lotus_position|meditation person in lotus position|pessoa na posicao de lotus cruzadas ioga lotus meditacao pernas posicao
    \\🧘‍♂️|lotus_position_man|meditation man in lotus position|homem na posicao de lotus ioga meditacao yoga
    \\🧘‍♀️|lotus_position_woman|meditation woman in lotus position|mulher na posicao de lotus ioga meditacao yoga
    \\🛀|bath|shower person taking bath|pessoa tomando banho agua banheira banho espuma pessoa
    \\🛌|sleeping_bed|person in bed|pessoa deitada na cama boa cama cochilo dormindo dormir hotel
    \\🧑‍🤝‍🧑|people_holding_hands|couple date people holding hands|pessoas de maos dadas amigos casal dadas gemeos maos parceiros
    \\👭|two_women_holding_hands|couple date women holding hands|duas mulheres de maos dadas amigas casal dadas gemeas maos parceiras
    \\👫|couple|date woman and man holding hands|homem e mulher de maos dadas amigos casal homem maos dadas mulher pessoas
    \\👬|two_men_holding_hands|couple date men holding hands|dois homens de maos dadas amigos casal dois homens gemeos homem irmaos
    \\💏|couplekiss|kiss|beijo amor beijar casal coracao pessoas
    \\👩‍❤️‍💋‍👨|couplekiss_man_woman|kiss: woman, man|
    \\👨‍❤️‍💋‍👨|couplekiss_man_man|kiss: man, man|
    \\👩‍❤️‍💋‍👩|couplekiss_woman_woman|kiss: woman, woman|
    \\💑|couple_with_heart|couple with heart|casal apaixonado casal casal com um coracao coracao pessoas romance
    \\👩‍❤️‍👨|couple_with_heart_woman_man|couple with heart: woman, man|
    \\👨‍❤️‍👨|couple_with_heart_man_man|couple with heart: man, man|
    \\👩‍❤️‍👩|couple_with_heart_woman_woman|couple with heart: woman, woman|
    \\👨‍👩‍👦|family_man_woman_boy|family: man, woman, boy|
    \\👨‍👩‍👧|family_man_woman_girl|family: man, woman, girl|
    \\👨‍👩‍👧‍👦|family_man_woman_girl_boy|family: man, woman, girl, boy|
    \\👨‍👩‍👦‍👦|family_man_woman_boy_boy|family: man, woman, boy, boy|
    \\👨‍👩‍👧‍👧|family_man_woman_girl_girl|family: man, woman, girl, girl|
    \\👨‍👨‍👦|family_man_man_boy|family: man, man, boy|
    \\👨‍👨‍👧|family_man_man_girl|family: man, man, girl|
    \\👨‍👨‍👧‍👦|family_man_man_girl_boy|family: man, man, girl, boy|
    \\👨‍👨‍👦‍👦|family_man_man_boy_boy|family: man, man, boy, boy|
    \\👨‍👨‍👧‍👧|family_man_man_girl_girl|family: man, man, girl, girl|
    \\👩‍👩‍👦|family_woman_woman_boy|family: woman, woman, boy|
    \\👩‍👩‍👧|family_woman_woman_girl|family: woman, woman, girl|
    \\👩‍👩‍👧‍👦|family_woman_woman_girl_boy|family: woman, woman, girl, boy|
    \\👩‍👩‍👦‍👦|family_woman_woman_boy_boy|family: woman, woman, boy, boy|
    \\👩‍👩‍👧‍👧|family_woman_woman_girl_girl|family: woman, woman, girl, girl|
    \\👨‍👦|family_man_boy|family: man, boy|
    \\👨‍👦‍👦|family_man_boy_boy|family: man, boy, boy|
    \\👨‍👧|family_man_girl|family: man, girl|
    \\👨‍👧‍👦|family_man_girl_boy|family: man, girl, boy|
    \\👨‍👧‍👧|family_man_girl_girl|family: man, girl, girl|
    \\👩‍👦|family_woman_boy|family: woman, boy|
    \\👩‍👦‍👦|family_woman_boy_boy|family: woman, boy, boy|
    \\👩‍👧|family_woman_girl|family: woman, girl|
    \\👩‍👧‍👦|family_woman_girl_boy|family: woman, girl, boy|
    \\👩‍👧‍👧|family_woman_girl_girl|family: woman, girl, girl|
    \\🗣️|speaking_head|speaking head|silhueta falando berro cabeca falando grito silhueta voz
    \\👤|bust_in_silhouette|user bust in silhouette|silhueta de busto busto misterio pessoas silhueta sombra
    \\👥|busts_in_silhouette|users group team busts in silhouette|silhueta de bustos amigos busto dupla pessoas silhueta
    \\🫂|people_hugging|people hugging|pessoas se abracando abracando abraco adeus amizade amor carinho
    \\👪|family|home parents child family|familia filho mae pai pessoas um filho
    \\🧑‍🧑‍🧒|family_adult_adult_child|family: adult, adult, child|familia: adulto, adulto, crianca adulto crianca familia
    \\🧑‍🧑‍🧒‍🧒|family_adult_adult_child_child|family: adult, adult, child, child|familia: adulto, adulto, crianca, crianca adulto adultos crianca criancas familia filha
    \\🧑‍🧒|family_adult_child|family: adult, child|familia: adulto, crianca adulto crianca familia
    \\🧑‍🧒‍🧒|family_adult_child_child|family: adult, child, child|familia: adulto, crianca, crianca adulto criancas familia
    \\👣|footprints|feet tracks footprints|pegadas corpo gravura pe pes descalcos rastro
    \\🫆|fingerprint|fingerprint|impressao digital identidade investigacao forense seguranca
    \\🐵|monkey_face|monkey face|rosto de macaco animal macaco rosto
    \\🐒|monkey|monkey|macaco animal
    \\🦍|gorilla|gorilla|gorila animal macaco
    \\🦧|orangutan|orangutan|orangotango macaco primata
    \\🐶|dog|pet dog face|rosto de cachorro animal cachorro rosto
    \\🐕|dog2|dog|cachorro animal cao
    \\🦮|guide_dog|guide dog|cao-guia acessibilidade cachorro cadela cao cega
    \\🐕‍🦺|service_dog|service dog|cao de servico accessibilidade assistencia cachorro cadela cao
    \\🐩|poodle|dog poodle|poodle animal cachorro
    \\🐺|wolf|wolf|rosto de lobo animal lobo rosto
    \\🦊|fox_face|fox|rosto de raposa animal bicho raposa rosto
    \\🦝|raccoon|raccoon|guaxinim animal astuto curioso travesso
    \\🐱|cat|pet cat face|rosto de gato animal felino gatinho gato rosto
    \\🐈|cat2|cat|gato animal felino
    \\🐈‍⬛|black_cat|black cat|gato preto animal azar dia das bruxas felino gata gato
    \\🦁|lion|lion|rosto de leao animal leao rosto zodiaco
    \\🐯|tiger|tiger face|rosto de tigre animal tigre
    \\🐅|tiger2|tiger|tigre animal
    \\🐆|leopard|leopard|leopardo animal onca
    \\🐴|horse|horse face|rosto de cavalo animal cavalo equino rosto
    \\🫎|moose|canada moose|alce animal cervo chifres galhada mamifero
    \\🫏|donkey|mule donkey|burro animais animal asno jegue mamifero
    \\🐎|racehorse|speed horse|cavalo animal corrida equestre
    \\🦄|unicorn|unicorn|rosto de unicornio animal rosto unicornio
    \\🦓|zebra|zebra|zebra animal listra listras
    \\🦌|deer|deer|cervo animal veado
    \\🦬|bison|bison|bisao animal bisonte bufalo rebanho
    \\🐮|cow|cow face|rosto de vaca animal fazenda leite muuu rosto
    \\🐂|ox|ox|boi animal touro zodiaco
    \\🐃|water_buffalo|water buffalo|bufalo-asiatico agua animal bufalo
    \\🐄|cow2|cow|vaca animal fazenda
    \\🐷|pig|pig face|rosto de porco animal porco rosto
    \\🐖|pig2|pig|porco animal
    \\🐗|boar|boar|javali animal
    \\🐽|pig_nose|pig nose|nariz de porco animal nariz porco rosto
    \\🐏|ram|ram|carneiro animal aries chifre zodiaco
    \\🐑|sheep|ewe|ovelha animal fazenda la
    \\🐐|goat|goat|cabra animal bode capricornio zodiaco
    \\🐪|dromedary_camel|desert camel|camelo animal camelo de uma so corcova corcova deserto dromedario
    \\🐫|camel|two-hump camel|camelo com duas corcovas animal camelo camelo asiatico com duas corcovas corcova deserto
    \\🦙|llama|llama|lhama alpaca animal guanaco la vicunha
    \\🦒|giraffe|giraffe|girafa animal
    \\🐘|elephant|elephant|elefante animal
    \\🦣|mammoth|mammoth|mamute animal extinto grande lanoso pre-historico
    \\🦏|rhinoceros|rhinoceros|rinoceronte animal
    \\🦛|hippopotamus|hippopotamus|hipopotamo animal
    \\🐭|mouse|mouse face|rosto de camundongo animal camundongo ratinho rato rosto
    \\🐁|mouse2|mouse|camundongo animal ratinho
    \\🐀|rat|rat|rato animal ratazana
    \\🐹|hamster|pet hamster|rosto de hamster animal hamster rosto
    \\🐰|rabbit|bunny rabbit face|rosto de coelho animal coelho rosto
    \\🐇|rabbit2|rabbit|coelho animal coelhinho coelhinho da pascoa
    \\🐿️|chipmunk|chipmunk|esquilo animal
    \\🦫|beaver|beaver|castor animal dentuco represa
    \\🦔|hedgehog|hedgehog|porco-espinho animal espinhoso ourico
    \\🦇|bat|bat|morcego animal vampiro
    \\🐻|bear|bear|rosto de urso animal rosto urso
    \\🐻‍❄️|polar_bear|polar bear|urso polar artico branco urso
    \\🐨|koala|koala|coala animal
    \\🐼|panda_face|panda|rosto de panda animal panda rosto
    \\🦥|sloth|sloth|preguica bicho-preguica devagar lenta lentidao preguicosa
    \\🦦|otter|otter|lontra brincalhona pesca
    \\🦨|skunk|skunk|gamba fedida fedido fedor
    \\🦘|kangaroo|kangaroo|canguru animal australia filhote joey marsupial
    \\🦡|badger|badger|texugo animal incomodar ratel texugo de mel
    \\🐾|feet|paw_prints paw prints|patas animal pata patinhas de cachorro pegada pegada de pata
    \\🦃|turkey|thanksgiving turkey|peru animal ave peru de natal
    \\🐔|chicken|chicken|galinha animal ave
    \\🐓|rooster|rooster|galo animal ave
    \\🐣|hatching_chick|hatching chick|pintinho chocando animal ave bebe chocando filhote galinha
    \\🐤|baby_chick|baby chick|pintinho de perfil animal ave bebe filhote galinha pintinho
    \\🐥|hatched_chick|front-facing baby chick|pintinho de frente animal ave bebe fihote galinha pintinho
    \\🐦|bird|bird|passaro animal
    \\🐧|penguin|penguin|pinguim animal antartica frio
    \\🕊️|dove|peace dove|pomba branca animal ave branca passaro paz pomba
    \\🦅|eagle|eagle|aguia passaro
    \\🦆|duck|duck|pato animal passaro
    \\🦢|swan|swan|cisne animal ave passaro patinho feio
    \\🦉|owl|owl|coruja passaro sabedoria
    \\🦤|dodo|dodo|dodo animal ave extinto grande mauricio
    \\🪶|feather|feather|pena leve passaro plumagem voo
    \\🦩|flamingo|flamingo|flamingo ave extravagante tropical
    \\🦚|peacock|peacock|pavao animal ave colorido orgulhoso pavoa
    \\🦜|parrot|parrot|papagaio animal ave fala passaro pirata
    \\🪽|wing|fly wing|asa angelical anjo ascender aviacao celestial
    \\🐦‍⬛|black_bird|black bird|passaro preto animal ave bico corvo gralha passarinho
    \\🪿|goose|honk goose|ganso animal ave bobo gansos grasno
    \\🐦‍🔥|phoenix|phoenix|fenix fantasia imortal passaro de fogo reemergir reencarnacao
    \\🐸|frog|frog|sapo animal rosto rosto de sapo
    \\🐊|crocodile|crocodile|crocodilo animal jacare
    \\🐢|turtle|slow turtle|tartaruga animal
    \\🦎|lizard|lizard|lagartixa animal lagarto reptil
    \\🐍|snake|snake|cobra animal reptil serpente
    \\🐲|dragon_face|dragon face|rosto de dragao animal dragao rosto
    \\🐉|dragon|dragon|dragao animal game of thrones
    \\🦕|sauropod|dinosaur sauropod|sauropode braquiosaurus braquiossauro brontossauro brontossuro dinossauro diplodoco
    \\🦖|t_rex|t-rex dinosaur|tiranossauro rex dinossauro t-rex
    \\🐳|whale|sea spouting whale|baleia esguichando agua animal baleia esguicho
    \\🐋|whale2|whale|baleia animal mar oceano
    \\🐬|dolphin|flipper dolphin|golfinho animal oceano
    \\🫍|orca|orca|orca baleia marinho oceano
    \\🦭|seal|seal|foca animal animal marinho leao marinho leao-marinho oceano
    \\🐟|fish|fish|peixe animal peixes pesca pescar signo de peixes
    \\🐠|tropical_fish|tropical fish|peixe tropical animal peixe
    \\🐡|blowfish|blowfish|baiacu animal peixe
    \\🦈|shark|shark|tubarao peixe
    \\🐙|octopus|octopus|polvo animal oceano octopus
    \\🐚|shell|sea beach spiral shell|caramujo animal concha concha do mar concha em espiral
    \\🪸|coral|coral|coral mar mudanca climatica oceano recife
    \\🪼|jellyfish|jellyfish|agua-viva ai animal aquario ferrao invertebrado
    \\🦀|crab|crab|caranguejo animal animal marinho cancer signo de cancer zodiaco
    \\🦞|lobster|lobster|lagosta animal bisque caldo fruto do mar garras
    \\🦐|shrimp|shrimp|camarao animal comida crustaceo
    \\🦑|squid|squid|lula animal comida molusco
    \\🦪|oyster|oyster|ostra frutos do mar mar mergulho perola
    \\🐌|snail|slow snail|caracol animal escargot
    \\🦋|butterfly|butterfly|borboleta beleza inseto
    \\🫌|monarch_butterfly|monarch butterfly|borboleta-monarca esperanca fragil inseto lagarta metamorfose migracao
    \\🐛|bug|bug|inseto animal centopeia lagarta
    \\🐜|ant|ant|formiga animal inseto
    \\🐝|bee|honeybee|abelha animal inseto natureza
    \\🪲|beetle|beetle|besouro animal bicho inseto
    \\🐞|lady_beetle|bug lady beetle|joaninha animal besouro inseto tipo de besouro
    \\🦗|cricket|cricket|grilo gafanhoto inseto
    \\🪳|cockroach|cockroach|barata animal baratas inseto nojento nojo
    \\🕷️|spider|spider|aranha animal dias das bruxas halloween inseto
    \\🕸️|spider_web|spider web|teia de aranha aranha halloween inseto teia
    \\🦂|scorpion|scorpion|escorpiao animal deserto inseto zodiaco
    \\🦟|mosquito|mosquito|mosquito aedes aegypti amarela animal chicungunha dengue
    \\🪰|fly|fly|mosca animal apodrecendo doenca inseto larva
    \\🪱|worm|worm|minhoca anelideo animal parasita verme
    \\🦠|microbe|germ microbe|microbio ameba bacteria ciencia virus
    \\💐|bouquet|flowers bouquet|buque aniversario flor planta romance
    \\🌸|cherry_blossom|flower spring cherry blossom|flor de cerejeira cereja cerejeira flor planta primavera
    \\💮|white_flower|white flower|flor branca carimbo carimbo de flor carimbo de parabens flor
    \\🪷|lotus|lotus|lotus beleza budismo calma flor flor de lotus hinduismo
    \\🏵️|rosette|rosette|roseta flor flor amarela planta primavera
    \\🌹|rose|flower rose|rosa flor
    \\🥀|wilted_flower|wilted flower|flor murcha flor morrendo murcha murchando
    \\🌺|hibiscus|hibiscus|hibisco flor planta primavera
    \\🌻|sunflower|sunflower|girassol flor planta
    \\🌼|blossom|blossom|flor florescer planta
    \\🌷|tulip|flower tulip|tulipa flor
    \\🪻|hyacinth|hyacinth|jacinto arbusto bluebonnet flor flor-cranio-do-dragao lavanda
    \\🌱|seedling|plant seedling|muda de planta brotar broto jovem muda planta jovem
    \\🪴|potted_plant|potted plant|vaso com planta casa chato decoracao nutrir planta plantar
    \\🌲|evergreen_tree|wood evergreen tree|conifera arvore arvore de pinheiro floresta natal pinheirinho
    \\🌳|deciduous_tree|wood deciduous tree|arvore caidica arvore arvore cheia caidica desfolha natureza
    \\🌴|palm_tree|palm tree|palmeira arvore arvore de palmeira coqueiro
    \\🌵|cactus|cactus|cacto deserto natureza planta seca
    \\🌾|ear_of_rice|sheaf of rice|planta de arroz arroz comida espiga espiga de arroz fazenda graos
    \\🌿|herb|herb|erva folha planta
    \\☘️|shamrock|shamrock|trevo irlanda irlandes planta trevo de tres folhas
    \\🍀|four_leaf_clover|luck four leaf clover|trevo de quatro folhas folhas irlandes planta quatro sorte sortudo
    \\🍁|maple_leaf|canada maple leaf|folha de bordo folha folha caida folha vermelha maple outono
    \\🍂|fallen_leaf|autumn fallen leaf|folhas caidas caidas cair folha folhas outono
    \\🍃|leaves|leaf leaf fluttering in wind|folha ao vento folha soprando vento
    \\🪹|empty_nest|empty nest|ninho vazio aninhando galhos lar ninho passarinho
    \\🪺|nest_with_eggs|nest with eggs|ninho com ovos aninhando galhos lar ninho ovo
    \\🍄|mushroom|fungus mushroom|cogumelo champignon fungo mario planta
    \\🪾|leafless_tree|leafless tree|arvore seca arvore sem folhas inverno seca
    \\🍇|grapes|grapes|uvas fruta uva
    \\🍈|melon|melon|melao fruta
    \\🍉|watermelon|watermelon|melancia fruta
    \\🍊|tangerine|orange mandarin tangerine|tangerina citrica fruta laranja
    \\🍋|lemon|lemon|limao azedo citrico fruta lima limao siciliano
    \\🍋‍🟩|lime|lime|lima acidez caipirinha citrica citrico drink fruta
    \\🍌|banana|fruit banana|banana fruta
    \\🍍|pineapple|pineapple|abacaxi comida fome fruta
    \\🥭|mango|mango|manga comida fruta tropical
    \\🍎|apple|red apple|maca vermelha fruta maca vermelha
    \\🍏|green_apple|fruit green apple|maca verde comida fome fruta maca verde
    \\🍐|pear|pear|pera comida fome fruta
    \\🍑|peach|peach|pessego fruta
    \\🍒|cherries|fruit cherries|cereja comida fome fruta frutas vermelhas
    \\🍓|strawberry|fruit strawberry|morango comida fome fruta frutas vermelhas
    \\🫐|blueberries|blueberries|mirtilos alimento azul baga blueberry comida fruta
    \\🥝|kiwi_fruit|kiwi fruit|kiwi comida fruta
    \\🍅|tomato|tomato|tomate fruta fruto legume vegetal
    \\🫒|olive|olive|azeitona alimento comida oliveira
    \\🥥|coconut|coconut|coco fruta palmeira pina colada
    \\🥑|avocado|avocado|abacate comida fruta
    \\🍆|eggplant|aubergine eggplant|berinjela beringela comida legume vegetal
    \\🥔|potato|potato|batata comida fome legume vegetal
    \\🥕|carrot|carrot|cenoura comida fome legume salada vegetal
    \\🌽|corn|ear of corn|milho comida espiga espiga de milho fome
    \\🌶️|hot_pepper|spicy hot pepper|pimenta apimentada apimentado tempero
    \\🫑|bell_pepper|bell pepper|pimentao alimento capsicum comida pimenta pimentao verde
    \\🥒|cucumber|cucumber|pepino comida fome legume picles salada
    \\🫝|pickle|pickle|picles condimento conserva fermentar pepino problema
    \\🥬|leafy_green|leafy green|verdura alface bok choy comida couve hamburguer repolho
    \\🥦|broccoli|broccoli|brocolis brocoli
    \\🧄|garlic|garlic|alho tempero
    \\🧅|onion|onion|cebola tempero
    \\🥜|peanuts|peanuts|amendoim comida
    \\🫘|beans|beans|feijoes alimento comida feijao grao legume
    \\🌰|chestnut|chestnut|castanha planta
    \\🫚|ginger_root|ginger root|gengibre cerveja comida erva especiaria natural
    \\🫛|pea_pod|pea pod|vagem comida edamame ervilha feijao grao legume
    \\🍄‍🟫|brown_mushroom|brown mushroom|cogumelo marrom champignon cogumelo comida fungo fungos
    \\🫜|root_vegetable|root vegetable|tuberculo beterraba legume nabo raiz vegetal
    \\🍞|bread|toast bread|pao pao de forma pao para fatiar restaurante torrada tostex
    \\🥐|croissant|croissant|croissant cafe da manha comida fome pao
    \\🥖|baguette_bread|baguette bread|baguete bisnaga comida pao pao frances
    \\🫓|flatbread|flatbread|pao sirio alimento arepa comida lavash naan pao
    \\🥨|pretzel|pretzel|pretzel pao torcido
    \\🥯|bagel|bagel|bagel cafe da manha chimia comida confeitaria pao rosca
    \\🥞|pancakes|pancakes|panquecas cafe da manha comida crepes fome
    \\🧇|waffle|waffle|waffle doce gofre wafel wafle
    \\🧀|cheese|cheese wedge|queijo comida fome queijo suico
    \\🍖|meat_on_bone|meat on bone|carne carne com osso carne no osso churras churrasco osso
    \\🍗|poultry_leg|meat chicken poultry leg|coxa de frango aves comida coxa coxinha fome
    \\🥩|cut_of_meat|cut of meat|corte de carne bife carne carne vermelha costela de cordeiro costeleta
    \\🥓|bacon|bacon|bacon comida fome toucinho
    \\🍔|hamburger|burger hamburger|hamburguer burguer cheese burguer restaurante
    \\🍟|fries|french fries|batata frita comida fast food fome fritas lanchonete
    \\🍕|pizza|pizza|pizza fatia restaurante
    \\🌭|hotdog|hot dog|cachorro-quente cachorro quente hot dog pao com salsicha pao com vina vina
    \\🥪|sandwich|sandwich|sanduiche pao pao de forma
    \\🌮|taco|taco|taco comida mexicana mexicano tacos
    \\🌯|burrito|burrito|burrito comida mexicana mexicano
    \\🫔|tamale|tamale|tamale alimento comida enrolado mexicano milho pamonha
    \\🥙|stuffed_flatbread|stuffed flatbread|pao recheado comida kebab pao recheio wrap
    \\🧆|falafel|falafel|falafel almondega grao de bico
    \\🥚|egg|egg|ovo comida fome
    \\🍳|fried_egg|breakfast cooking|ovo frito comida culinaria frigideira ovo ovo estrelado
    \\🥘|shallow_pan_of_food|paella curry shallow pan of food|cacarola com comida cacarola comida fome paella panela
    \\🍲|stew|pot of food|panela ensopado restaurante tigela de comida
    \\🫕|fondue|fondue|fondue alimento chocolate comida derretido panela
    \\🥣|bowl_with_spoon|bowl with spoon|tigela com colher cafe da manha cereal prato de sopa
    \\🥗|green_salad|green salad|salada verde comida fome restaurante salada verde
    \\🍿|popcorn|popcorn|pipoca balde cinema
    \\🧈|butter|butter|manteiga laticinio margarina
    \\🧂|salt|salt|sal comida condimento sabor saleiro salgado
    \\🥫|canned_food|canned food|comida enlatada lata
    \\🍱|bento|bento box|bento almoco japones caixa caixa de bento restaurante
    \\🍘|rice_cracker|rice cracker|biscoito de arroz arroz bolacha de arroz cracker
    \\🍙|rice_ball|rice ball|arroz japones arroz bolinho de arroz comida fome japones onigiri
    \\🍚|rice|cooked rice|arroz cozido arroz comida fome restaurante
    \\🍛|curry|curry rice|arroz com curry arroz curry curry e arroz restaurante
    \\🍜|ramen|noodle steaming bowl|lamen comida fome macarrao miojo quentinha
    \\🍝|spaghetti|pasta spaghetti|espaguete comida fome italiano macarrao macarronada
    \\🍠|sweet_potato|roasted sweet potato|batata assada assada batata batata-doce doce restaurante
    \\🍢|oden|oden|oden espetinho frutos do mar frutos do mar no espetinho restaurante
    \\🍣|sushi|sushi|sushi comida japonesa restaurante restaurante japones sashimi
    \\🍤|fried_shrimp|tempura fried shrimp|camarao frito camarao camarao empanado restaurante tempura
    \\🍥|fish_cake|fish cake with swirl|bolinho de peixe croquete peixe redemoinho restaurante
    \\🥮|moon_cake|moon cake|bolo lunar bolo da lua comida confeitaria festival festival chines
    \\🍡|dango|dango|dango bolinho de mochi bolinho de mochi no espetinho bolinho japones comida doce
    \\🥟|dumpling|dumpling|bolinho asiatico asiatico bolinho chines dumpling empanada gyoza
    \\🥠|fortune_cookie|fortune cookie|biscoito da sorte biscoito chines biscoito da fortuna profecia sorte
    \\🥡|takeout_box|takeout box|caixa para viagem caixinha para levar delivery marmita
    \\🍦|icecream|soft ice cream|sorvete italiano doce fome sobremesa sorvete sorvete de casquinha sorvete de massa
    \\🍧|shaved_ice|shaved ice|raspadinha de gelo gelo raspadinha restaurante sobremesa
    \\🍨|ice_cream|ice cream|sorvete creme gelo restaurante sobremesa
    \\🍩|doughnut|doughnut|donut comida fome restaurante rosquinha sonho doce
    \\🍪|cookie|cookie|biscoito bolacha comida cookie doce fome
    \\🎂|birthday|party birthday cake|bolo de aniversario aniversario bolo comemoracao doce feliz aniversario
    \\🍰|cake|dessert shortcake|pao de lo de morango bolo bolo recheado doce fatia fatia de bolo pao de lo
    \\🧁|cupcake|cupcake|cupcake acucar bolinho bolo comida confeitaria confeito
    \\🥧|pie|pie|torta abobora carne doce fatia fatia de torta fruta
    \\🍫|chocolate_bar|chocolate bar|chocolate barra barra de chocolate doce fome
    \\🍬|candy|sweet candy|bala balinha doce
    \\🍭|lollipop|lollipop|pirulito bala doce
    \\🍮|custard|custard|pudim pudim de leite pudim de ovos restaurante
    \\🍯|honey_pot|honey pot|pote de mel mel pote restaurante
    \\🍼|baby_bottle|milk baby bottle|mamadeira bebe leite leitinho mamar nenem
    \\🥛|milk_glass|glass of milk|copo de leite copo leite
    \\☕|coffee|cafe espresso hot beverage|cafe cafeina cafezinho cha inverno quente
    \\🫖|teapot|teapot|bule alimento bebida cha chaleira comida
    \\🍵|tea|green breakfast teacup without handle|xicara de cha sem alca bebida cha cha verde xicara xicara de cha
    \\🍶|sake|sake|saque bar bebida copo garrafa garrafa e copo de saque japones
    \\🍾|champagne|bottle bubbly celebration bottle with popping cork|garrafa de champanhe aniversario bar champagne champanha champanhe cidra
    \\🍷|wine_glass|wine glass|vinho bar bebida calice de vinho restaurante taca
    \\🍸|cocktail|drink cocktail glass|coquetel bar beber bebida cachaca happy hour
    \\🍹|tropical_drink|summer vacation tropical drink|bebida tropical bar bebida coquetel coquetel de frutas drink happy hour
    \\🍺|beer|drink beer mug|cerveja bar bebida caneca caneca de cerveja chopp
    \\🍻|beers|drinks clinking beer mugs|canecas de cerveja bar caneca cerveja chope chopp restaurante
    \\🥂|clinking_glasses|cheers toast clinking glasses|tacas brindando brinde champagne champanhe comemoracao taca
    \\🥃|tumbler_glass|whisky tumbler glass|copo bar bebida drink whisky
    \\🫗|pouring_liquid|pouring liquid|derramando liquido acabou acidente agua bebida copo derramar
    \\🥤|cup_with_straw|cup with straw|copo com canudo agua canudo copo refrigerante suco
    \\🧋|bubble_tea|bubble tea|cha perolado bebida bolha bubble tea cha comida
    \\🧃|beverage_box|beverage box|suco de caixa caixa de suco caixinha de suco suco suquinho
    \\🧉|mate|mate|mate bebida chimarrao cuia de chimarrao terere
    \\🧊|ice_cube|ice|cubo de gelo gelado gelo iceberg
    \\🥢|chopsticks|chopsticks|hashi comida japonesa pauzinhos
    \\🍽️|plate_with_cutlery|dining dinner fork and knife with plate|prato com talheres almoco faca fome garfo jantar prato
    \\🍴|fork_and_knife|cutlery fork and knife|garfo e faca almoco comer comida faca fome garfo
    \\🥄|spoon|spoon|colher talher
    \\🔪|hocho|knife cut chop kitchen knife|faca de cozinha chef cozinhar faca
    \\🫙|jar|jar|jarro armazenar condimento conserva jarra molho
    \\🏺|amphora|amphora|anfora ornamento chines vaso vaso chines
    \\🌍|earth_africa|globe world international globe showing europe-africa|globo mostrando europa e africa africa europa terra
    \\🌎|earth_americas|globe world international globe showing americas|globo mostrando as americas america as americas terra
    \\🌏|earth_asia|globe world international globe showing asia-australia|globo mostrando asia e oceania asia australia oceania planeta terra terra
    \\🌐|globe_with_meridians|world global international globe with meridians|globo com meridianos meridianos
    \\🗺️|world_map|travel world map|mapa-mundi geografia mapa mundo
    \\🗾|japan|map of japan|mapa do japao japao mapa
    \\🧭|compass|compass|bussola bussola magnetica direcao ima magnetico navegacao
    \\🏔️|mountain_snow|snow-capped mountain|montanha com neve alpes frio montanha neve
    \\⛰️|mountain|mountain|montanha natureza
    \\🛘|landslide|landslide|deslizamento avalanche desastre montanha perigo rochas terremoto
    \\🌋|volcano|volcano|vulcao erupcao vulcanica lava natureza
    \\🗻|mount_fuji|mount fuji|monte fuji montanha
    \\🏕️|camping|camping|acampamento barraca
    \\🏖️|beach_umbrella|beach with umbrella|praia e guarda-sol guarda-sol praia
    \\🏜️|desert|desert|deserto clima seco
    \\🏝️|desert_island|desert island|ilha deserta ilha palmeira praia
    \\🏞️|national_park|national park|parque nacional parque parque com rio reserva florestal rio
    \\🏟️|stadium|stadium|estadio arena
    \\🏛️|classical_building|classical building|predio grego arquitetura classico grego
    \\🏗️|building_construction|building construction|construcao guindaste obra
    \\🧱|bricks|brick|tijolo argamassa argila cimento muro parede terra
    \\🪨|rock|rock|pedra pedregulho pesado rocha seixo solido
    \\🪵|wood|wood|madeira lenha madeira serrada tora tronco
    \\🛖|hut|hut|cabana abrigo casa yurt
    \\🏘️|houses|houses|casas
    \\🏚️|derelict_house|derelict house|casa abandonada casa
    \\🏠|house|house|casa construcao domicilio lar residencia
    \\🏡|house_with_garden|house with garden|casa com jardim casa construcao jardim lar
    \\🏢|office|office building|edificio comercial edificio escritorio
    \\🏣|post_office|japanese post office|correio japones correio japones oriental predio
    \\🏤|european_post_office|post office|correio europeu predio
    \\🏥|hospital|hospital|hospital doente internado medico predio
    \\🏦|bank|bank|banco predio
    \\🏨|hotel|hotel|hotel predio
    \\🏩|love_hotel|love hotel|motel amor hotel predio
    \\🏪|convenience_store|convenience store|loja de conveniencia 24 horas 24h conveniencia loja predio
    \\🏫|school|school|escola colegio predio predio da escola
    \\🏬|department_store|department store|loja de departamentos departamentos estabelecimento comercial loja
    \\🏭|factory|factory|fabrica predio
    \\🏯|japanese_castle|japanese castle|castelo japones castelo japones pagoda pagode predio
    \\🏰|european_castle|castle|castelo castelo europeu castelo medieval predio
    \\💒|wedding|marriage wedding|capela de casamento capela casamento romance
    \\🗼|tokyo_tower|tokyo tower|torre de toquio japao toquio torre
    \\🗽|statue_of_liberty|statue of liberty|estatua da liberdade estatua liberdade
    \\⛪|church|church|igreja capela crista cristao missa predio
    \\🕌|mosque|mosque|mesquita isla muculmano religiao
    \\🛕|hindu_temple|hindu temple|templo hindu hindu templo
    \\🕍|synagogue|synagogue|sinagoga judaismo judeu judia religiao templo
    \\⛩️|shinto_shrine|shinto shrine|santuario japones japones oriental religiao santuario xintoismo
    \\🕋|kaaba|kaaba|caaba isla isla muculmano religiao
    \\⛲|fountain|fountain|fonte agua chafariz praca
    \\⛺|tent|camping tent|barraca acampamento acampar
    \\🌁|foggy|karl foggy|enevoado bruma cerracao neblina nevoa nevoeiro
    \\🌃|night_with_stars|night with stars|noite estrelada cidade a noite estrelas noite predios
    \\🏙️|cityscape|skyline cityscape|cidade predios urbano
    \\🌄|sunrise_over_mountains|sunrise over mountains|aurora sobre montanhas montanha nascer do sol sobre as montanhas sol da manha
    \\🌅|sunrise|sunrise|aurora sobre agua amanhecer aurora natureza oceano rio
    \\🌆|city_sunset|cityscape at dusk|cidade ao anoitecer anoitecer cidade noite paisagem por do sol
    \\🌇|city_sunrise|sunset|por do sol anoitecer calor cidade entardecer por do sol sobre predios
    \\🌉|bridge_at_night|bridge at night|ponte a noite noite ponte pontilhao
    \\♨️|hotsprings|hot springs|chamas calor fogo fumaca quente
    \\🎠|carousel_horse|carousel horse|carrossel cavalo cavalo de carrossel entretenimento parque de diversao
    \\🛝|playground_slide|playground slide|escorregador brincar brinquedo escorregar parque de diversoes parquinho
    \\🎡|ferris_wheel|ferris wheel|roda gigante entretenimento gigante parque de diversoes roda
    \\🎢|roller_coaster|roller coaster|montanha russa entretenimento montanha parque de diversoes parque tematico russa
    \\💈|barber|barber pole|barbearia barbeiro barber pole cortar cabelo poste poste de barbeiro
    \\🎪|circus_tent|circus tent|circo entretenimento lona lona de circo tenda
    \\🚂|steam_locomotive|train locomotive|locomotiva trem vapor veiculo
    \\🚃|railway_car|railway car|vagao de trem bonde eletrico ferroviario transporte trem trolebus
    \\🚄|bullettrain_side|train high-speed train|trem de alta velocidade alta bala japones trem trens veiculo
    \\🚅|bullettrain_front|train bullet train|trem de alta velocidade japones bala ferrovia japao trem velocidade veloz
    \\🚆|train2|train|trem ferrovia veiculo
    \\🚇|metro|metro|metro trem tunel tunel subterraneo veiculo
    \\🚈|light_rail|light rail|trem urbano chegada cheguei leve trem veiculo
    \\🚉|station|station|estacao estacao de trem metro trem
    \\🚊|tram|tram|bonde eletrico trolebus veiculo
    \\🚝|monorail|monorail|monotrilho trem veiculo
    \\🚞|mountain_railway|mountain railway|estrada de ferro na montanha carro estrada de ferro montanha teleferico veiculo
    \\🚋|train|tram car|bonde bonde eletrico carro trolebus veiculo
    \\🚌|bus|bus|onibus transporte publico veiculo
    \\🚍|oncoming_bus|oncoming bus|onibus se aproximando onibus se aproximando veiculo
    \\🚎|trolleybus|trolleybus|trolebus bonde eletrico onibus onibus movido a eletricidade veiculo
    \\🚐|minibus|minibus|van mini onibus onibus veiculo veraneio
    \\🚑|ambulance|ambulance|ambulancia veiculo
    \\🚒|fire_engine|fire engine|carro do corpo de bombeiros bombeiro caminhao do corpo de bombeiros carro fogo incendio
    \\🚓|police_car|police car|viatura policial carro patrulha policia veiculo
    \\🚔|oncoming_police_car|oncoming police car|viatura policial se aproximando policia veiculo viatura policial
    \\🚕|taxi|taxi|taxi veiculo
    \\🚖|oncoming_taxi|oncoming taxi|taxi se aproximando chegada taxi transporte veiculo
    \\🚗|car|red_car automobile|carro automovel veiculo
    \\🚘|oncoming_automobile|oncoming automobile|carro se aproximando automovel carona carro chegada se aproximando
    \\🚙|blue_car|sport utility vehicle|suv carro trailer veiculo veiculo recreacional
    \\🛻|pickup_truck|pickup truck|caminhonete automovel cacamba caminhao carro picape
    \\🚚|truck|delivery truck|caminhao de entrega caminhao veiculo
    \\🚛|articulated_lorry|articulated lorry|caminhao caminhao articulado semi trailer veiculo
    \\🚜|tractor|tractor|trator obra veiculo
    \\🏎️|racing_car|racing car|carro de corrida automobilismo carro corrida
    \\🏍️|motorcycle|motorcycle|motocicleta corrida moto veiculo
    \\🛵|motor_scooter|motor scooter|scooter monareta motinho moto motoca
    \\🦽|manual_wheelchair|manual wheelchair|cadeira de rodas manual acessibilidade cadeira de rodas
    \\🦼|motorized_wheelchair|motorized wheelchair|cadeira de rodas motorizada acessibilidade
    \\🛺|auto_rickshaw|auto rickshaw|automovel riquixa autorriquixa tuk tuk
    \\🚲|bike|bicycle|bicicleta bike veiculo
    \\🛴|kick_scooter|kick scooter|patinete brinquedo
    \\🛹|skateboard|skateboard|skate rodinhas skatista
    \\🛼|roller_skate|roller skate|patins de rodas esporte patinacao patins rodas roller
    \\🚏|busstop|bus stop|ponto de onibus bus busao onibus ponto transporte publico
    \\🛣️|motorway|motorway|estrada caminho viagem viajar
    \\🛤️|railway_track|railway track|trilhos trem
    \\🛢️|oil_drum|oil drum|barril de oleo barril lata latao oleo
    \\⛽|fuelpump|fuel pump|posto de gasolina abastecer alcool bomba combustivel gasolina posto
    \\🛞|wheel|wheel|roda carro circulo direcao girar pneu
    \\🚨|rotating_light|911 emergency police car light|sirene carro da policia farol policial luz de viatura policial luz giratoria
    \\🚥|traffic_light|horizontal traffic light|semaforo horizontal cruzamento horizontal luz semaforo sinal sinaleira
    \\🚦|vertical_traffic_light|semaphore vertical traffic light|semaforo vertical cruzamento luz semaforo sinal sinaleira transito
    \\🛑|stop_sign|stop sign|sinal de pare pare sinal
    \\🚧|construction|wip construction|em construcao construcao simbolo simbolo para “em construcao”
    \\🛙|lighthouse|lighthouse|farol esperanca iluminacao luz mar maritimo navegacao
    \\⚓|anchor|ship anchor|ancora marinha navegar sinal
    \\🛟|ring_buoy|life preserver ring buoy|boia colete flutuar guarda-vidas guardar nadar
    \\⛵|boat|sailboat|barco a vela barco iate navegar oceano praia resort
    \\🛶|canoe|canoe|canoa barco
    \\🚤|speedboat|ship speedboat|lancha barco ferias praia veiculo verao
    \\🛳️|passenger_ship|cruise passenger ship|cruzeiro barco embarcacao navio passageiros veiculo
    \\⛴️|ferry|ferry|balsa barco ferry ferry boat ferry-boat navegar
    \\🛥️|motor_boat|motor boat|barco lancha motor navio veiculo
    \\🚢|ship|ship|navio aquatico barco cruzeiro ferias veiculo
    \\✈️|airplane|flight airplane|aviao aereo veiculo viajar voar voo
    \\🛩️|small_airplane|flight small airplane|aviao pequeno aereo aviao jatinho jato pequeno veiculo
    \\🛫|flight_departure|airplane departure|aviao decolando aviao decolar ferias fui partindo partiu
    \\🛬|flight_arrival|airplane arrival|aviao aterrissando aterrissagem aterrissando aviao chegando pousando veiculo
    \\🪂|parachute|parachute|paraquedas asa-delta paraquedista parasail saltar de paraquedas
    \\💺|seat|seat|assento cadeira poltrona
    \\🚁|helicopter|helicopter|helicoptero veiculo viagem viajar voo
    \\🚟|suspension_railway|suspension railway|estrada de ferro suspensa estrada de ferro suspensao trem veiculo
    \\🚠|mountain_cableway|mountain cableway|teleferico de montanha bonde cabo cabo suspenso usado em telefericos nas montanhas montanha teleferico teleferico na montanha
    \\🚡|aerial_tramway|aerial tramway|teleferico aerea bonde gondola linha veiculo
    \\🛰️|artificial_satellite|orbit space satellite|satelite antena espaco
    \\🚀|rocket|ship launch rocket|foguete espaco veiculo
    \\🛸|flying_saucer|ufo flying saucer|disco voador alienigena disco et extra ovni terrestre
    \\🛎️|bellhop_bell|bellhop bell|sineta hotel portaria sino
    \\🧳|luggage|luggage|mala bagagem rodinhas viagem
    \\⌛|hourglass|time hourglass done|ampulheta areia tempo
    \\⏳|hourglass_flowing_sand|time hourglass not done|ampulheta contando o tempo ampulheta areia cheia contando em cima hora
    \\⌚|watch|time watch|relogio de pulso hora relogio tempo
    \\⏰|alarm_clock|morning alarm clock|despertador alarme atrasada atrasado hora horario
    \\⏱️|stopwatch|stopwatch|cronometro relogio tempo
    \\⏲️|timer_clock|timer clock|relogio temporizador cronometro relogio timer
    \\🕰️|mantelpiece_clock|mantelpiece clock|relogio de mesa relogio relogio antigo
    \\🕛|clock12|twelve o’clock|12 horas 12h00 doze meia-noite meio-dia relogio
    \\🕧|clock1230|twelve-thirty|doze e meia 12h30 relogio
    \\🕐|clock1|one o’clock|1 hora 13h 1h 1h00 relogio uma
    \\🕜|clock130|one-thirty|uma e meia 1:30 13:30 13h30 1h30 relogio
    \\🕑|clock2|two o’clock|2 horas 14h 2h 2h00 duas relogio
    \\🕝|clock230|two-thirty|duas e meia 2:30 2h30 relogio
    \\🕒|clock3|three o’clock|3 horas 15h 3:00 3h00 hora horario
    \\🕞|clock330|three-thirty|tres e meia 3:30 3h30 relogio
    \\🕓|clock4|four o’clock|4 horas 4:00 4h00 horario quatro relogio
    \\🕟|clock430|four-thirty|quatro e meia 4h30 relogio
    \\🕔|clock5|five o’clock|5 horas 5h00 cinco relogio
    \\🕠|clock530|five-thirty|cinco e meia 17h30 5h30 relogio
    \\🕕|clock6|six o’clock|6 horas 18h 6h00 relogio seis
    \\🕡|clock630|six-thirty|seis e meia 18h30 6h30 relogio
    \\🕖|clock7|seven o’clock|7 horas 19h 7h00 relogio sete
    \\🕢|clock730|seven-thirty|sete e meia 7:30 7h30 relogio
    \\🕗|clock8|eight o’clock|8 horas 8:00 8h00 hora oito relogio
    \\🕣|clock830|eight-thirty|oito e meia 8:30 8h30 relogio
    \\🕘|clock9|nine o’clock|9 horas 21h 9h00 nove relogio
    \\🕤|clock930|nine-thirty|nove e meia 9:30 9h30 hora relogio
    \\🕙|clock10|ten o’clock|10 horas 10h00 22h dez relogio
    \\🕥|clock1030|ten-thirty|dez e meia 10h30 22h30 relogio
    \\🕚|clock11|eleven o’clock|11 horas 11:00 11h00 onze relogio
    \\🕦|clock1130|eleven-thirty|onze e meia 11h30 23h30 relogio
    \\🌑|new_moon|new moon|lua nova escuro lua lua negra noite nova
    \\🌒|waxing_crescent_moon|waxing crescent moon|lua crescente concava concava crescente lua noite
    \\🌓|first_quarter_moon|first quarter moon|quarto crescente lua lua de quarto crescente quarto
    \\🌔|moon|waxing_gibbous_moon waxing gibbous moon|lua crescente convexa convexa crescente lua
    \\🌕|full_moon|full moon|lua cheia cheia lua luar
    \\🌖|waning_gibbous_moon|waning gibbous moon|lua minguante convexa convexa lua minguante
    \\🌗|last_quarter_moon|last quarter moon|quarto minguante lua lua de quarto minguante quarto
    \\🌘|waning_crescent_moon|waning crescent moon|lua minguante concava concava lua minguante
    \\🌙|crescent_moon|night crescent moon|lua crescente crescente lua
    \\🌚|new_moon_with_face|new moon face|rosto da lua nova lua lua nova lua nova com rosto rosto
    \\🌛|first_quarter_moon_with_face|first quarter moon face|rosto da lua de quarto crescente crescente lua noite quarto rosto
    \\🌜|last_quarter_moon_with_face|last quarter moon face|rosto da lua de quarto minguante lua lua com rosto lua de quarto minguante quarto minguante quarto minguante com rosto rosto
    \\🌡️|thermometer|thermometer|termometro clima temperatura tempo
    \\☀️|sunny|weather sun|sol clima dia claro raios solar tempo
    \\🌝|full_moon_with_face|full moon face|rosto da lua cheia cheia lua lua cheia com rosto lua com rosto rosto
    \\🌞|sun_with_face|summer sun with face|rosto do sol praia rosto sol
    \\🪐|ringed_planet|ringed planet|planeta com aneis aneis planeta saturnino saturno
    \\⭐|star|star|estrela branca media amarela astronomia estrela
    \\🌟|star2|glowing star|estrela brilhante brilhante brilho cintilante estrela luminosa reluzente
    \\🌠|stars|shooting star|estrela cadente cadente cai estrela
    \\🌌|milky_way|milky way|via lactea ceu espaco estrelado
    \\☁️|cloud|cloud|nuvem clima
    \\⛅|partly_sunny|weather cloud sun behind cloud|sol por tras das nuvens clima nublado nuvem sol
    \\⛈️|cloud_with_lightning_and_rain|cloud with lightning and rain|chuva com trovao chuva clima nuvem relampago temporal trovao
    \\🌤️|sun_behind_small_cloud|sun behind small cloud|sol com nuvens clima ensolarado nublado nuvem sol
    \\🌥️|sun_behind_large_cloud|sun behind large cloud|nublado clima nuvem sol
    \\🌦️|sun_behind_rain_cloud|sun behind rain cloud|sol com chuva chuva clima nuvem sol
    \\🌧️|cloud_with_rain|cloud with rain|nuvem com chuva chovendo chuva clima nuvem
    \\🌨️|cloud_with_snow|cloud with snow|nuvem com neve clima frio neve nuvem
    \\🌩️|cloud_with_lightning|cloud with lightning|nuvem com relampago clima nuvem nuvem com trovao relampago
    \\🌪️|tornado|tornado|tornado clima furacao nuvem
    \\🌫️|fog|fog|nevoeiro clima furacao neblina nuvem
    \\🌬️|wind_face|wind face|rosto de vento clima nuvem rosto soprar sopro vento
    \\🌀|cyclone|swirl cyclone|ciclone clima espiral furacao tonto twister
    \\🌈|rainbow|rainbow|arco-iris chuva clima gay lesbica lgbt
    \\🌂|closed_umbrella|weather rain closed umbrella|guarda-chuva fechado chuva chuvoso guarda-chuva
    \\☂️|open_umbrella|umbrella|guarda-chuva acessorio chuva clima sombrinha aberta
    \\☔|umbrella|rain weather umbrella with rain drops|sombrinha na chuva acessorio chuva clima gotas guarda-chuva sombrinha
    \\⛱️|parasol_on_ground|beach_umbrella umbrella on ground|guarda-sol chuva clima praia sol sombra
    \\⚡|zap|lightning thunder high voltage|alta tensao alta eletricidade natureza perigo relampago sinal
    \\❄️|snowflake|winter cold weather snowflake|floco de neve clima floco frio neve
    \\☃️|snowman_with_snow|winter christmas snowman|boneco de neve boneco clima frio inverno neve
    \\⛄|snowman|winter snowman without snow|boneco de neve sem neve boneco frio inverno neve
    \\☄️|comet|comet|cometa espaco estrela cadente meteoro satelite
    \\🪋|meteor|meteor|meteoro apocalipse bola de fogo espaco estrela gravidade queda
    \\🔥|fire|burn fire|fogo chama
    \\💧|droplet|water droplet|gota com suor engracado gota de suor suor
    \\🌊|ocean|sea water wave|onda agua mar oceano praia surfe
    \\🎃|jack_o_lantern|halloween jack-o-lantern|abobora de halloween abobora comemoracao dia das bruxas halloween jack lanterna
    \\🎄|christmas_tree|christmas tree|arvore de natal arvore comemoracao natal pinheirinho
    \\🎆|fireworks|festival celebration fireworks|fogos de artificio ano novo comemoracao fogos
    \\🎇|sparkler|sparkler|vela estrela comemoracao fogo de artificio fogo de artificio vela estrela
    \\🧨|firecracker|firecracker|bombinha artificio bomba chiando dinamite estourar
    \\✨|sparkles|shiny sparkles|brilhos * brilhantes estrelas faiscas magica
    \\🎈|balloon|party birthday balloon|balao aniversario celebracao comemoracao festa parabens
    \\🎉|tada|hooray party party popper|cone de festa alegria aniversario celebrar comemoracao cone eba
    \\🎊|confetti_ball|confetti ball|confete bola celebracao comemoracao eba oba
    \\🎋|tanabata_tree|tanabata tree|arvore de tanabata arvore comemoracao estrelas festival japonesa papel
    \\🎍|bamboo|pine decoration|decoracao de pinhos bambu comemoracao decoracao de pinhas japones pinha
    \\🎎|dolls|japanese dolls|bonecas japonesas bonecas comemoracao festival japanesas japones
    \\🎏|flags|carp streamer|bandeira de carpas bandeira carpas comemoracao koinobori
    \\🎐|wind_chime|wind chime|carrilhao de vento sino som vento
    \\🎑|rice_scene|moon viewing ceremony|contemplacao da lua cerimonia de contemplacao da lua comemoracao contemplacao lua
    \\🧧|red_envelope|red envelope|envelope vermelho boa sorte dinheiro hongbao lai see presente
    \\🎀|ribbon|ribbon|laco de fita comemoracao fita laco presente
    \\🎁|gift|present birthday christmas wrapped gift|presente comemoracao embrulhado mimo
    \\🎗️|reminder_ribbon|reminder ribbon|fita de lembrete celebracao comemoracao laco lembrete
    \\🎟️|tickets|admission tickets|ingresso de cinema cinema entrada ingresso ticket
    \\🎫|ticket|ticket|ingresso entretenimento
    \\🎖️|medal_military|military medal|medalha militar condecoracao medalha militar premio
    \\🏆|trophy|award contest winner trophy|trofeu campea campeao premio
    \\🏅|medal_sports|gold winner sports medal|medalha esportiva medalha vitoria
    \\🥇|1st_place_medal|gold 1st place medal|medalha de ouro 1o. lugar medalha ouro vitoria
    \\🥈|2nd_place_medal|silver 2nd place medal|medalha de prata 2o. lugar medalha prata segundo
    \\🥉|3rd_place_medal|bronze 3rd place medal|medalha de bronze 3o. lugar bronze medalha terceiro
    \\⚽|soccer|sports soccer ball|bola de futebol bola futebol jogar
    \\⚾|baseball|sports baseball|bola de beisebol beisebol bola esportes
    \\🥎|softball|softball|softbol bola esporte luva softball
    \\🏀|basketball|sports basketball|bola de basquete basquete bola cesta esporte jogo
    \\🏐|volleyball|volleyball|bola de volei bola jogar jogo volei
    \\🏈|football|sports american football|bola de futebol americano americano bola esporte futebol super bowl
    \\🏉|rugby_football|rugby football|bola de rugby americano bola esporte futebol rugby
    \\🎾|tennis|sports tennis|tenis bola esporte raquete
    \\🥏|flying_disc|flying disc|frisbee disco esporte ultimate voador
    \\🎳|bowling|bowling|boliche bola jogo strike
    \\🏏|cricket_game|cricket game|criquete betes bola jogo taco
    \\🏑|field_hockey|field hockey|hoquei de campo bola campo hoquei jogo taco
    \\🏒|ice_hockey|ice hockey|hoquei no gelo disco gelo hoquei jogo taco
    \\🥍|lacrosse|lacrosse|lacrosse bastao bola esporte gol raquete
    \\🏓|ping_pong|ping pong|pingue-pongue mesa pingpong raquete tenis
    \\🏸|badminton|badminton|badminton jogo peteca raquete
    \\🥊|boxing_glove|boxing glove|luva de boxe boxe esporte luta luva
    \\🥋|martial_arts_uniform|martial arts uniform|quimono de artes marciais artes esporte faixa judo karate marciais
    \\🥅|goal_net|goal net|gol esporte futebol goleira goleiro rede
    \\⛳|golf|flag in hole|bandeira no buraco bandeira buraco esporte golfe
    \\⛸️|ice_skate|skating ice skate|patins de gelo gelo patinacao patins
    \\🎣|fishing_pole_and_fish|fishing pole|pesca entretenimento peixe pescador pescaria recreacao
    \\🤿|diving_mask|diving mask|mascara de mergulho esnorquel mascara mergulhador mergulho scuba snorkel
    \\🎽|running_shirt_with_sash|marathon running shirt|camiseta de corrida camiseta corrida esporte faixa
    \\🎿|ski|skis|esqui bota esporte esquiar neve
    \\🛷|sled|sled|treno neve toboga
    \\🥌|curling_stone|curling stone|pedra de curling curling jogo pedra
    \\🎯|dart|target bullseye|no alvo alvo certeiro dardos jogo mira mosca
    \\🪀|yo_yo|yo-yo|ioio brinquedo flutua
    \\🪁|kite|kite|pipa papagaio planar voar
    \\🔫|gun|shoot weapon water pistol|pistola d’agua agua arma ferramenta pistola revolver
    \\🎱|8ball|pool billiards pool 8 ball|bilhar bola oito jogo
    \\🔮|crystal_ball|fortune crystal ball|bola de cristal adivinhacao bola cristal destino futuro prever
    \\🪄|magic_wand|magic wand|varinha magica bruxa condao magia magica mago varinha
    \\🎮|video_game|play controller console video game|videogame controle game jogo jogos playstation video
    \\🕹️|joystick|joystick|joystick atari controle game jogo video
    \\🎰|slot_machine|slot machine|caca-niquel aposta azar cassino jogo maquina
    \\🎲|game_die|dice gambling game die|jogo de dado dado dados jogo sorte
    \\🧩|jigsaw|puzzle piece|quebra-cabeca dica encaixe peca
    \\🧸|teddy_bear|teddy bear|ursinho de pelucia bichinho brinquedo enchimento pelucia ursinho urso
    \\🪅|pinata|pinata|pinhata cinco de maio comemoracao doce festa festival
    \\🪩|mirror_ball|disco party mirror ball|globo de espelhos balada boate bola brilho danca dancar
    \\🪆|nesting_dolls|nesting dolls|boneca russa boneca matriosca matrioska russa
    \\♠️|spades|spade suit|naipe de espadas baralho carta espadas jogo naipe
    \\♥️|hearts|heart suit|naipe de copas baralho carta copas jogo naipe s2
    \\♦️|diamonds|diamond suit|naipe de ouros baralho carta jogo naipe ouro
    \\♣️|clubs|club suit|naipe de paus baralho carta jogo naipe paus
    \\♟️|chess_pawn|chess pawn|peao de xadrez peao truque xadrez
    \\🃏|black_joker|joker|curinga baralho carta coringa jogo joker
    \\🀄|mahjong|mahjong red dragon|dragao vermelho de mahjong dragao jogo mahjong peca vermelho
    \\🎴|flower_playing_cards|flower playing cards|carta de flores baralho carta de baralho flores hanafuda jogo de baralho
    \\🎭|performing_arts|theater drama performing arts|mascara arte ator atriz drama dramatica entretenimento
    \\🖼️|framed_picture|framed picture|quadro emoldurado arte emoldurado moldura museu pintura quadro
    \\🎨|art|design paint artist palette|paleta de tintas arte artista artistica museu paleta pintor
    \\🧵|thread|thread|carretel agulha barbante costura linha
    \\🪡|sewing_needle|sewing needle|agulha de costura agulha alfaiataria bordados costura linha pontos
    \\🧶|yarn|yarn|novelo bola croche la trico tricotar
    \\🪢|knot|knot|no amarrar corda cordel emaranhado fio laco
    \\👓|eyeglasses|glasses|oculos acessorio
    \\🕶️|dark_sunglasses|sunglasses|oculos escuros oculos oculos de sol
    \\🥽|goggles|goggles|oculos de protecao mergulho natacao oculos olhos protecao ski
    \\🥼|lab_coat|lab coat|jaleco cientista dr. experiencia experimento medico
    \\🦺|safety_vest|safety vest|colete salva-vidas colete emergencia refletivo salva-vidas seguranca
    \\👔|necktie|shirt formal necktie|gravata acessorio roupa
    \\👕|shirt|tshirt t-shirt|camiseta camisa roupa
    \\👖|jeans|pants jeans|jeans calca roupa
    \\🧣|scarf|scarf|cachecol frio inverno pescoco
    \\🧤|gloves|gloves|luvas inverno luva mao
    \\🧥|coat|coat|casaco agasalho blusa frio jaqueta
    \\🧦|socks|socks|meias meia meiao
    \\👗|dress|dress|vestido peca unica roupa
    \\👘|kimono|kimono|quimono roupa vestir
    \\🥻|sari|sari|sari india indiana roupa vestido
    \\🩱|one_piece_swimsuit|one-piece swimsuit|maio banho nadar praia roupa
    \\🩲|swim_brief|briefs|cueca banho intima nadar praia roupa
    \\🩳|shorts|shorts|shorts banho bermuda nadar praia roupa
    \\👙|bikini|beach bikini|biquini banho piscina praia roupa
    \\👚|womans_clothes|woman’s clothes|roupas femininas azul blusa camiseta feminina roupa
    \\🪭|folding_hand_fan|sensu folding hand fan|leque dobravel abanar arejar balancar calor danca flertar
    \\👛|purse|purse|bolsinha acessorio bolsa moeda niqueleira porta
    \\👜|handbag|bag handbag|bolsa de mao acessorio bolsa fashion mala mao
    \\👝|pouch|bag clutch bag|bolsa pequena acessorio bolsa carteira fashion pequena
    \\🛍️|shopping|bags shopping bags|sacolas de compras compras presente sacolas shopping
    \\🎒|school_satchel|backpack|mochila bolsa escola viagem viajar
    \\🩴|thong_sandal|thong sandal|chinelo alpargatas piscina praia rasteirinha sandalia
    \\👞|mans_shoe|shoe man’s shoe|sapato masculino acessorio sapatos
    \\👟|athletic_shoe|sneaker sport running running shoe|tenis de corrida acessorio correr corrida esportivo sapato tenis
    \\🥾|hiking_boot|hiking boot|bota de trekking acampamento acampar bota caminhada marrom
    \\🥿|flat_shoe|flat shoe|sapatilha confortavel sapatilha de bale sapato sem fivela
    \\👠|high_heel|shoe high-heeled shoe|sapato de salto alto acessorio alto chique fashion moda mulher
    \\👡|sandal|shoe woman’s sandal|sandalia feminina acessorio feminino medio salto sandalia
    \\🩰|ballet_shoes|ballet shoes|sapatilha de bale bailarina bale danca sapatilha
    \\👢|boot|woman’s boot|bota feminina acessorio bota calcado feminina medio salto
    \\🪮|hair_pick|hair pick|pente de cabelo afro cabelo crespo pente pente garfo pentear
    \\👑|crown|king queen royal crown|coroa acessorio familia real game of thrones medieval rainha
    \\👒|womans_hat|woman’s hat|chapeu feminino acessorio chapeu fashion feminino
    \\🎩|tophat|hat classy top hat|cartola chapeu chique entretenimento roupa
    \\🎓|mortar_board|education college university graduation graduation cap|chapeu de formatura capelo chapeu comemoracao formatura
    \\🧢|billed_cap|billed cap|bone bone de beisebol chapeu
    \\🪖|military_helmet|military helmet|capacete militar capacete exercito guerra guerreiro militar soldado
    \\⛑️|rescue_worker_helmet|rescue worker’s helmet|capacacete de socorrista ajuda branca capacete cruz primeiros resgate
    \\📿|prayer_beads|prayer beads|rosario de oracao acessorio oracao religiao reza rosario
    \\💄|lipstick|makeup lipstick|batom cosmeticos makeup maquiagem vermelho
    \\💍|ring|wedding marriage engaged ring|anel diamante romance
    \\💎|gem|diamond gem stone|pedra preciosa diamante joia
    \\🔇|mute|sound volume muted speaker|alto-falante silenciado alto-falante calar mudo mute quieto silenciar
    \\🔈|speaker|speaker low volume|alto-falante com volume baixo alto-falante baixo mudo musica silencio som
    \\🔉|sound|volume speaker medium volume|alto-falante com volume medio alto-falante baixo diminuir medio som volume
    \\🔊|loud_sound|volume speaker high volume|alto-falante com volume alto alto alto-falante gritar musica som volume
    \\📢|loudspeaker|announcement loudspeaker|buzina alto alto-falante aviso comunicado discurso
    \\📣|mega|megaphone|megafone aplausos comunicacao
    \\📯|postal_horn|postal horn|corneta postal corneta correios postal
    \\🔔|bell|sound notification bell|sino capela
    \\🔕|no_bell|volume off bell with slash|sino silenciado mudo notificacao proibido quieto sem som silencio
    \\🎼|musical_score|musical score|partitura musical musica partitura
    \\🎵|musical_note|musical note|nota musical musica nota
    \\🎶|notes|music musical notes|notas musicais musica nota notas
    \\🎙️|studio_microphone|podcast studio microphone|microfone de estudio estudio microfone musica
    \\🎚️|level_slider|level slider|controle de volume controle musica volume
    \\🎛️|control_knobs|control knobs|botoes giratorios botoes controle musica
    \\🎤|microphone|sing microphone|microfone cantar entretenimento karaoke mic musica
    \\🎧|headphones|music earphones headphone|fones de ouvido entretenimento fone musica ouvido som
    \\📻|radio|podcast radio|radio radiola som video
    \\🎷|saxophone|saxophone|saxofone instrumento instrumento musical musica sax
    \\🎺|trumpet|trumpet|trompete instrumento instrumento musical musica
    \\🪊|trombone|trombone|trombone instrumento jazz musica sopro triste
    \\🪗|accordion|accordion|acordeao concertina instrumento musica sanfona
    \\🎸|guitar|rock guitar|guitarra instrumento instrumento musical musica
    \\🎹|musical_keyboard|piano musical keyboard|teclado musical instrumento instrumento musical musica piano teclado
    \\🎻|violin|violin|violino instrumento instrumento musical musica
    \\🪕|banjo|banjo|banjo cordas instrumento musica
    \\🥁|drum|drum|tambor baquetas musica percussao
    \\🪘|long_drum|long drum|tambor comprido atabaque batida comprido conga instrumento percussao
    \\🪇|maracas|shaker maracas|maracas chacoalhar chocalho danca festa instrumento maraca
    \\🪈|flute|recorder flute|flauta banda flautim instrumento marcial musica
    \\🪉|harp|harp|harpa amor cupido instrumento musica orquestra
    \\📱|iphone|smartphone mobile mobile phone|telefone celular celular telefone telefone movel
    \\📲|calling|call incoming mobile phone with arrow|telefone celular com seta celular chamada fazer ligar receber seta
    \\☎️|phone|telephone|telefone no gancho gancho telefone
    \\📞|telephone_receiver|phone call telephone receiver|telefone aparelho de telefone comunicacao
    \\📟|pager|pager|pager comunicacao
    \\📠|fax|fax machine|fax comunicacao maquina de fax
    \\🔋|battery|power battery|pilha bateria
    \\🪫|low_battery|low battery|pouca bateria acabando bateria cansado descarregada eletronico energia
    \\🔌|electric_plug|electric plug|tomada eletrica cabo eletrica eletricidade energia plugue tomada
    \\💻|computer|desktop screen laptop|laptop computador notebook pc pessoal trabalho
    \\🖥️|desktop_computer|desktop computer|computador de mesa computador desktop mesa monitor
    \\🖨️|printer|printer|impressora acessorio computador documento impressao imprimir
    \\⌨️|keyboard|keyboard|teclado acessorio computador digitacao
    \\🖱️|computer_mouse|computer mouse|mouse acessorio computador
    \\🖲️|trackball|trackball|trackball acessorio bolinha computador mouse
    \\💽|minidisc|computer disk|minidisc computacao disc disco hd md mini
    \\💾|floppy_disk|save floppy disk|disquete computador disco disco flexivel
    \\💿|cd|optical disk|cd blu-ray computador disco dvd
    \\📀|dvd|dvd|dvd blu-ray cd computador disco
    \\🧮|abacus|abacus|abaco calculadora calculo matematica numero
    \\🎥|movie_camera|film video movie camera|camera de cinema camera cinema entretenimento filmar filme hollywood
    \\🎞️|film_strip|film frames|rolo de filmes cinema filme
    \\📽️|film_projector|film projector|projetor de filmes cinema filme projetor video
    \\🎬|clapper|film clapper board|claquete cena entretenimento filme tomada
    \\📺|tv|television|televisao canal tv video
    \\📷|camera|photo camera|camera foto selfie video
    \\📸|camera_flash|photo camera with flash|camera com flash camera flash foto fotografia video
    \\📹|video_camera|video camera|camera de video camera filmadora video
    \\📼|vhs|videocassette|videocassete cassete fita vhs video
    \\🔍|mag|search zoom magnifying glass tilted left|lupa para a esquerda aumento busca esquerda ferramenta lente lupa
    \\🔎|mag_right|magnifying glass tilted right|lupa para a direita aumento busca direita ferramenta lente lupa
    \\🕯️|candle|candle|vela acesa luz
    \\💡|bulb|idea light light bulb|lampada eletrica ideia luz quadrinhos tenho uma ideia
    \\🔦|flashlight|flashlight|lanterna eletrica ferramenta luz
    \\🏮|izakaya_lantern|lantern red paper lantern|lanterna vermelha de papel bar izakaya lanterna papel restaurante vermelha
    \\🪔|diya_lamp|diya lamp|lampada de oleo diya lampada oleo
    \\📔|notebook_with_decorative_cover|notebook with decorative cover|caderno decorado agenda caderno capa decoracao escola livro
    \\📕|closed_book|closed book|livro fechado apostila fechado livro
    \\📖|book|open_book open book|livro aberto aberto biblioteca leitura lendo ler livraria
    \\📗|green_book|green book|livro verde biblioteca caderno colegio escola estudar lendo
    \\📘|blue_book|blue book|livro azul apostila azul escola estudo leitura livro
    \\📙|orange_book|orange book|livro laranja apostila cartilha laranja livro
    \\📚|books|library books|livros biblioteca estudando estudar leitura lendo ler
    \\📓|notebook|notebook|caderno folhas
    \\📒|ledger|ledger|livro contabil caderno
    \\📃|page_with_curl|page with curl|pagina dobrada dobrado documento pagina papel
    \\📜|scroll|document scroll|pergaminho rolo de papel
    \\📄|page_facing_up|document page facing up|pagina voltada para cima documento oficial pagina papel
    \\📰|newspaper|press newspaper|jornal noticias
    \\🗞️|newspaper_roll|press rolled-up newspaper|jornal enrolado enrolado jornal noticias
    \\📑|bookmark_tabs|bookmark tabs|marcadores de pagina marcador marcar pagina
    \\🔖|bookmark|bookmark|marcador de pagina livro marcador pagina
    \\🏷️|label|tag label|etiqueta identificar rotulo
    \\🪙|coin|coin|moeda dinheiro dolar euro metal ouro
    \\💰|moneybag|dollar cream money bag|saco de dinheiro dinheiro dolares saco
    \\🪎|treasure_chest|treasure chest|bau de tesouro dinheiro joia joias ouro prata premio
    \\💴|yen|yen banknote|nota de iene cedula dinheiro grana iene moeda nota
    \\💵|dollar|money dollar banknote|nota de dolar dinheiro dolar moeda nota nota bancaria
    \\💶|euro|euro banknote|nota de euro cedula dinheiro euro grana moeda nota
    \\💷|pound|pound banknote|nota de libra cedula dinheiro grana libra moeda nota
    \\💸|money_with_wings|dollar money with wings|dinheiro voando asas banco cedula dinheiro dinheiro indo embora nota
    \\💳|credit_card|subscription credit card|cartao de credito banco cartao credito debito dinheiro
    \\🧾|receipt|receipt|recibo contabilidade escrituracao evidencia fatura prova
    \\💹|chart|chart increasing with yen|grafico subindo com iene ascendente ascensao crescimento dinheiro grafico
    \\✉️|envelope|letter email envelope|envelope carta correspondencia e-mail email
    \\📧|email|e-mail|e-mail carta comunicacao correspondencia
    \\📨|incoming_envelope|incoming envelope|envelope chegando carta chegando comunicacao correspondencia e-mail envelope
    \\📩|envelope_with_arrow|envelope with arrow|envelope com seta carta comunicacao correspondencia e-mail email envelope
    \\📤|outbox_tray|outbox tray|bandeja de saida bandeja caixa comunicacao correspondencia enviada saida
    \\📥|inbox_tray|inbox tray|bandeja de entrada bandeja caixa comunicacao correspondencia e-mail email
    \\📦|package|shipping package|pacote caixa embrulho
    \\📫|mailbox|closed mailbox with raised flag|caixa de correio fechada com bandeira levantada bandeira caixa correio correspondencia fechada levantada
    \\📪|mailbox_closed|closed mailbox with lowered flag|caixa de correio fechada com bandeira abaixada abaixada bandeira caixa correio correspondencia fechada
    \\📬|mailbox_with_mail|open mailbox with raised flag|caixa de correio aberta com bandeira levantada aberta bandeira caixa de correspondencia aberta com bandeira levantada correspondencia
    \\📭|mailbox_with_no_mail|open mailbox with lowered flag|caixa de correio aberta com bandeira abaixada aberta bandeira caixa de correspondencia aberta com bandeira abaixada caixa de correspondencia aberta e vazia correspondencia
    \\📮|postbox|postbox|caixa de correio caixa carta correio correspondencia enviar
    \\🗳️|ballot_box|ballot box with ballot|urna eleitoral com cedula cedula eleicao eleitoral urna votar voto
    \\✏️|pencil2|pencil|lapis
    \\✒️|black_nib|black nib|ponta de caneta tinteiro caneta ponta preto tinta tinteiro
    \\🖋️|fountain_pen|fountain pen|caneta tinteiro caneta destro tinteiro
    \\🖊️|pen|pen|caneta esferografica tinteiro
    \\🖌️|paintbrush|paintbrush|pincel pintando pintar
    \\🖍️|crayon|crayon|giz de cera cera desenho giz vermelho
    \\📝|memo|pencil document note memo|memorando anotacoes caderno comunicacao lapis notas
    \\🪌|eraser|eraser|borracha apagar correcao desenho desfazer equivoco erro
    \\💼|briefcase|business briefcase|maleta mala pasta
    \\📁|file_folder|directory file folder|pasta de arquivos arquivo pasta
    \\📂|open_file_folder|open file folder|pasta de arquivos aberta aberta abrir arquivo pasta
    \\🗂️|card_index_dividers|card index dividers|divisores de pastas arquivo divisor indice organizador pasta
    \\📅|date|calendar schedule|calendario data datas
    \\📆|calendar|schedule tear-off calendar|calendario com folhas destacaveis calendario data destacaveis destacavel dia folha
    \\🗒️|spiral_notepad|spiral notepad|bloco espiral bloco caderno espiral
    \\🗓️|spiral_calendar|spiral calendar|calendario espiral bloco calendario data espiral
    \\📇|card_index|card index|indice de cartoes indice
    \\📈|chart_with_upwards_trend|graph metrics chart increasing|grafico subindo crescimento diagrama grafico grafico de tendencia de crescimento tendencia de crescimento
    \\📉|chart_with_downwards_trend|graph metrics chart decreasing|grafico caindo diagrama grafico grafico de tendencia negativa negativa tendencia negativa
    \\📊|bar_chart|stats metrics bar chart|grafico de barras barra diagrama grafico
    \\📋|clipboard|clipboard|prancheta anotacoes
    \\📌|pushpin|location pushpin|tacha alfinete
    \\📍|round_pushpin|location round pushpin|tacha redonda alfinete localizacao mapa redonda tacha
    \\📎|paperclip|paperclip|clipe de papel clipe
    \\🖇️|paperclips|linked paperclips|clipes de papel conectados clipe clipes clipes de papel
    \\📏|straight_ruler|straight ruler|regua reta regua
    \\📐|triangular_ruler|triangular ruler|regua triangular angulo geometria matematica regua triangular triangulo
    \\✂️|scissors|cut scissors|tesoura aberta cortar ferramenta
    \\🗃️|card_file_box|card file box|caixa de arquivos arquivo caixa cartao documentos ficheiro
    \\🗄️|file_cabinet|file cabinet|gavetas de escritorio arquivo escritorio gabinete gavetas
    \\🗑️|wastebasket|trash wastebasket|lixeira cesto lixo
    \\🔒|lock|security private locked|cadeado fechado trancado
    \\🔓|unlock|security unlocked|cadeado aberto aberto cadeado destrancado
    \\🔏|lock_with_ink_pen|locked with pen|cadeado com caneta cadeado caneta privacidade privado tinteiro
    \\🔐|closed_lock_with_key|security locked with key|cadeado fechado com chave cadeado chave fechado seguro trancado
    \\🔑|key|lock password key|chave senha trancado trancar
    \\🗝️|old_key|old key|chave antiga antiga chave fechadura
    \\🪍|net_with_handle|net with handle|rede com cabo armadilha capturar coletar malha
    \\🔨|hammer|tool hammer|martelo construcao ferramenta martelada reparo
    \\🪓|axe|axe|machado cortar madeira partir
    \\⛏️|pick|pick|picareta ferramenta mineracao
    \\⚒️|hammer_and_pick|hammer and pick|martelo e picareta ferramenta geologia martelo picareta
    \\🛠️|hammer_and_wrench|hammer and wrench|martelo e chave-inglesa chave chave-inglesa ferramenta inglesa martelo
    \\🗡️|dagger|dagger|adaga arma faca
    \\⚔️|crossed_swords|crossed swords|espadas cruzadas arma batalha cruzadas espadas guerra
    \\💣|bomb|boom bomb|bomba emocao engracado explosao explosivo perigo
    \\🪃|boomerang|boomerang|bumerangue aborigene arma australia rebote repercussao
    \\🏹|bow_and_arrow|archery bow and arrow|arco e flecha arco arma flecha sagitario zodiaco
    \\🛡️|shield|shield|escudo arma
    \\🪚|carpentry_saw|carpentry saw|serrote carpinteiro cortar ferramenta madeira serra serrar
    \\🔧|wrench|tool wrench|chave inglesa chave ferramenta inglesa obra reforma
    \\🪛|screwdriver|screwdriver|chave de fenda ferramenta
    \\🔩|nut_and_bolt|nut and bolt|porca e parafuso construcao ferramenta parafuso porca
    \\⚙️|gear|gear|engrenagem ferramenta
    \\🗜️|clamp|clamp|bracadeira compressao ferramenta morsa torno
    \\⚖️|balance_scale|balance scale|balanca ferramenta justica libra peso zodiaco
    \\🦯|probing_cane|white cane|bengala para cegos acessibilidade bengala cega cego cegueira deficiente
    \\🔗|link|link|link aneis corrente dois simbolo vinculo
    \\⛓️‍💥|broken_chain|broken chain|corrente quebrada algema corrente liberdade quebrada quebrando quebrar
    \\⛓️|chains|chains|correntes corrente metal
    \\🪝|hook|hook|gancho atracao para venda bandido curva pegar prender
    \\🧰|toolbox|toolbox|caixa de ferramentas caixa ferramenta mecanico vermelha
    \\🧲|magnet|magnet|ima atracao ferradura magnetico positivo-negativo
    \\🪜|ladder|ladder|escada degrau mao subir
    \\🪏|shovel|shovel|pa buraco cavar pazinha
    \\⚗️|alembic|alembic|alambique ferramenta quimica
    \\🧪|test_tube|test tube|tubo de ensaio ciencia ensaio experiencia experimento laboratorio quimica
    \\🧫|petri_dish|petri dish|placa de petri bacteria biologia biologista biologo ciencia cultura
    \\🧬|dna|dna|dna biologista biologo codigo evolucao gene
    \\🔬|microscope|science laboratory investigate microscope|microscopio ciencia ferramenta microscopico
    \\🔭|telescope|telescope|telescopio ciencia ferramenta
    \\📡|satellite|signal satellite antenna|antena parabolica antena comunicacao parabolica satelite
    \\💉|syringe|health hospital needle syringe|seringa agulha injecao medico remedio vacina
    \\🩸|drop_of_blood|drop of blood|gota de sangue doacao gota medicina menstruacao sangrar sangue
    \\💊|pill|health medicine pill|comprimido capsula medicina medico pilula remedio
    \\🩹|adhesive_bandage|adhesive bandage|atadura adesiva adesiva atadura bandaid bandeide curativo
    \\🩼|crutch|crutch|muleta ajuda bastao bengala deficiencia desculpa lesao
    \\🩺|stethoscope|stethoscope|estetoscopio coracao medica medicina medico tum tum
    \\🩻|x_ray|x-ray|raio x doutor esqueleto medico ossos radiografia
    \\🚪|door|door|porta fechada
    \\🛗|elevator|elevator|elevador acessibilidade descer elevar subir
    \\🪞|mirror|mirror|espelho especulo maquiagem refletor reflexao reflexo
    \\🪟|window|window|janela abertura ar fresco quadro transparente
    \\🛏️|bed|bed|cama dormir hotel sono
    \\🛋️|couch_and_lamp|couch and lamp|sofa e luminaria hotel lampada sofa
    \\🪑|chair|chair|cadeira assento sentar
    \\🚽|toilet|wc toilet|vaso sanitario banheiro patente privada sanitario toalete vaso
    \\🪠|plunger|plunger|desentupidor banheiro coco encanador fezes sanitario
    \\🚿|shower|bath shower|chuveiro agua banho ducha
    \\🛁|bathtub|bathtub|banheira banho
    \\🪤|mouse_trap|mouse trap|ratoeira armadilha atrair isca prender queijo
    \\🪒|razor|razor|lamina afiada afiado barbeador barbear depilar gilete
    \\🧴|lotion_bottle|lotion bottle|frasco de locao condicionador creme frasco hidratante locao protetor
    \\🧷|safety_pin|safety pin|alfinete de seguranca alfinete fralda punk rock
    \\🧹|broom|broom|vassoura bruxa limpar limpeza varrer
    \\🧺|basket|basket|cesta agricola agricultura lavanderia lavoura piquenique
    \\🧻|roll_of_paper|toilet roll of paper|rolo de papel higienico papel rolo toalha
    \\🪣|bucket|bucket|balde baldinho barril
    \\🧼|soap|soap|sabonete banho barra espuma limpar limpeza
    \\🫧|bubbles|bubbles|bolhas agua aquatica aquatico arroto bolha
    \\🪥|toothbrush|toothbrush|escova de dentes banheiro dental dentes escova higiene
    \\🧽|sponge|sponge|esponja absorcao absorvente encharcar limpeza porosa
    \\🧯|fire_extinguisher|fire extinguisher|extintor de incendio apagar extinguir extintor fogo incendio
    \\🛒|shopping_cart|shopping cart|carrinho de compras carrinho compras mercado supermercado
    \\🚬|smoking|cigarette|cigarro e permitido fumar fumante fumar fumo simbolo
    \\⚰️|coffin|funeral coffin|caixao caixao funerario funeral morte velorio
    \\🪦|headstone|headstone|lapide cemiterio descanse em paz morto rip sepultura
    \\⚱️|funeral_urn|funeral urn|urna funeraria cinzas funeral morte urna
    \\🧿|nazar_amulet|nazar amulet|olho grego amuleto conta grego mau-olhado micanga nazar
    \\🪬|hamsa|hamsa|hamsa amuleto fatima guia mao
    \\🗿|moyai|stone moai|moai estatua moyai rosto
    \\🪧|placard|placard|placa aviso cartaz demonstracao letreiro piquete
    \\🪪|identification_card|identification card|cartao de identificacao carta cartao carteira cracha credenciais documento
    \\🏧|atm|atm sign|simbolo de caixa automatico atm automatico banco caixa dinheiro eletronico
    \\🚮|put_litter_in_its_place|litter in bin sign|simbolo de lixeira coloque o lixo no lixo lata lixeira lixo simbolo
    \\🚰|potable_water|potable water|agua potavel agua beber potavel simbolo torneira
    \\♿|wheelchair|accessibility wheelchair symbol|simbolo de cadeira de rodas acesso cadeira rodas simbolo sinal
    \\🚹|mens|men’s room|banheiro masculino banheiro homem lavatorio masculino simbolo toalete
    \\🚺|womens|women’s room|banheiro feminino banheiro feminino lavabo lavatorio mulher simbolo
    \\🚻|restroom|toilet restroom|banheiro lavabo sanitario simbolo toalete
    \\🚼|baby_symbol|baby symbol|simbolo de bebe bebe fralda fraldario simbolo trocar
    \\🚾|wc|toilet restroom water closet|wc latrina lavabo privada toalete vaso sanitario
    \\🛂|passport_control|passport control|controle de passaportes controle passaporte
    \\🛃|customs|customs|alfandega aduana aduaneira bens federal impostos
    \\🛄|baggage_claim|airport baggage claim|restituicao de bagagem aeroporto area bagagem bagagens esteira ferias
    \\🛅|left_luggage|left luggage|deposito de bagagem bagagem deposito esquecida malas servico
    \\⚠️|warning|wip warning|aviso atencao cuidado sinal
    \\🚸|children_crossing|children crossing|criancas atravessando atravessando crianca criancas pedestre simbolo trafego
    \\⛔|no_entry|limit no entry|entrada proibida entrada entre nao placa proibida proibido
    \\🚫|no_entry_sign|block forbidden prohibited|proibido entrada nao proibida simbolo sinal
    \\🚳|no_bicycles|no bicycles|proibido andar de bicicleta bicicleta nao permitidas proibido sem
    \\🚭|no_smoking|no smoking|proibido fumar cigarro fumar nao e permitido fumar proibido simbolo
    \\🚯|do_not_litter|no littering|proibido jogar lixo no chao jogar lixo nao nao jogue lixo no chao proibido simbolo
    \\🚱|non_potable_water|non-potable_water non-potable water|agua nao potavel agua consumo impropria nao potavel proibido
    \\🚷|no_pedestrians|no pedestrians|proibida a passagem de pedestres nao passagem pedestre permitidos proibida proibido
    \\📵|no_mobile_phones|no mobile phones|proibido o uso de telefone celular cel celular nao permitidos proibido sem
    \\🔞|underage|no one under eighteen|proibido para menores de 18 anos 18 anos dezoito idade menor menores
    \\☢️|radioactive|radioactive|radioativo perigo radiacao radiativo simbolo sinal
    \\☣️|biohazard|biohazard|risco biologico biologico ciencia perigo residuos residuos biologicos risco
    \\⬆️|arrow_up|up arrow|seta para cima cardinal direcao norte seta
    \\↗️|arrow_upper_right|up-right arrow|seta para cima e para a direita diagonal direcao direita flecha intercardinal nordeste
    \\➡️|arrow_right|right arrow|seta para a direita direcao direita flecha leste seta
    \\↘️|arrow_lower_right|down-right arrow|seta para baixo e para a direita diagonal direcao direita flecha inferior intercardinal
    \\⬇️|arrow_down|down arrow|seta para baixo abaixo baixo cardinal direcao embaixo flecha
    \\↙️|arrow_lower_left|down-left arrow|seta para baixo e para a esquerda diagonal direcao esquerda flecha inferior intercardinal
    \\⬅️|arrow_left|left arrow|seta para a esquerda atras direcao esquerda flecha oeste seta
    \\↖️|arrow_upper_left|up-left arrow|seta para cima e para a esquerda diagonal superior esquerda direcao flecha intercardinal noroeste seta
    \\↕️|arrow_up_down|up-down arrow|seta para cima e para baixo flecha para baixo para cima seta vertical
    \\↔️|left_right_arrow|left-right arrow|seta para esquerda e direita flecha horizontal lados seta
    \\↩️|leftwards_arrow_with_hook|return right arrow curving left|seta curva da direita para a esquerda curva flecha retorno seta seta curva da direita para esquerda
    \\↪️|arrow_right_hook|left arrow curving right|seta curva da esquerda para a direita curva flecha retorno seta seta curva da esquerda para direita
    \\⤴️|arrow_heading_up|right arrow curving up|seta para a direita curvada para cima curva flecha seta seta curva de baixo para cima seta para cima
    \\⤵️|arrow_heading_down|right arrow curving down|seta para a direita curvada para baixo curva embaixo flecha seta curva de cima para baixo seta para baixo
    \\🔃|arrows_clockwise|clockwise vertical arrows|setas verticais no sentido horario flechas recarregar sentido horario seta setas setas em sentido horario na vertical
    \\🔄|arrows_counterclockwise|sync counterclockwise arrows button|botao de setas em sentido anti-horario anti-horario atualizar botao de setas no sentido anti-horario sentido anti-horario seta
    \\🔙|back|back arrow|seta "back" flecha seta seta para a esquerda seta para voltar voltar
    \\🔚|end|end arrow|seta "end" fim fim com seta para a esquerda final seta seta para a esquerda
    \\🔛|on|on! arrow|seta "on!" flecha marca on on! seta
    \\🔜|soon|soon arrow|seta "soon" “soon” com seta para a direita em breve flecha seta simbolo “soon”
    \\🔝|top|top arrow|seta "top" cima para cima seta seta "top seta para cima
    \\🛐|place_of_worship|place of worship|local de culto culto local sagrado oracao religiao reza
    \\⚛️|atom_symbol|atom symbol|simbolo de atomo ateismo ateu atomo simbolo do ateismo
    \\🕉️|om|om|om hindu religiao
    \\✡️|star_of_david|star of david|estrela de davi davi estrela judaico judeu religiao
    \\☸️|wheel_of_dharma|wheel of dharma|roda do dharma budista dharma religiao roda
    \\☯️|yin_yang|yin yang|yin yang religiao tao taoista taoistas yang yin
    \\✝️|latin_cross|latin cross|cruz latina cristao cruz religiao
    \\☦️|orthodox_cross|orthodox cross|cruz ortodoxa cristao cruz religiao
    \\☪️|star_and_crescent|star and crescent|estrela e lua crescente isla muculmano religiao simbolo isla
    \\☮️|peace_symbol|peace symbol|simbolo da paz paz simbolo
    \\🕎|menorah|menorah|menora candelabro candelabro judeu castical judaismo memorah
    \\🔯|six_pointed_star|dotted six-pointed star|estrela de seis pontas adivinhacao destino seis pontas
    \\🪯|khanda|khanda|khanda deg tegh fateh fe khalsa religiao sikh
    \\♈|aries|aries|signo de aries aries carneiro zodiaco
    \\♉|taurus|taurus|signo de touro boi touro zodiaco
    \\♊|gemini|gemini|signo de gemeos gemeos zodiaco
    \\♋|cancer|cancer|signo de cancer cancer caranguejo zodiaco
    \\♌|leo|leo|signo de leao leao zodiaco
    \\♍|virgo|virgo|signo de virgem virgem zodiaco
    \\♎|libra|libra|signo de libra balanca justica libra signo de virgem zodiaco
    \\♏|scorpius|scorpio|signo de escorpiao escorpiao zodiaco
    \\♐|sagittarius|sagittarius|signo de sagitario arqueiro sagitario zodiaco
    \\♑|capricorn|capricorn|signo de capricornio cabra capricornio zodiaco
    \\♒|aquarius|aquarius|signo de aquario agua aquario zodiaco
    \\♓|pisces|pisces|signo de peixes peixes zodiaco
    \\⛎|ophiuchus|ophiuchus|signo de ofiuco cobra ofiuco ophiuchus serpente zodiaco
    \\🔀|twisted_rightwards_arrows|shuffle shuffle tracks button|botao de musicas aleatorias cruzadas flechas seta setas setas cruzadas em direcao a direita
    \\🔁|repeat|loop repeat button|botao de repetir flechas horario repetir sentido horario seta
    \\🔂|repeat_one|repeat single button|botao de repetir uma unica faixa botao de repetir horario numero 1 repetir repetir uma vez
    \\▶️|arrow_forward|play button|botao reproduzir direita play reproduzir seta seta para a direita
    \\⏩|fast_forward|fast-forward button|botao avancar avancar direita dupla flechas passar para a frente
    \\⏭️|next_track_button|next track button|botao de proxima faixa avancar flechas duplas passar para frente proxima cena proxima faixa
    \\⏯️|play_or_pause_button|play or pause button|botao de reproduzir ou pausar botao direita pausar pause play
    \\◀️|arrow_backward|reverse button|botao de voltar esquerda seta seta para a esquerda triangulo voltar
    \\⏪|rewind|fast reverse button|botao de retroceder dupla esquerda retroceder seta seta dupla para a esquerda
    \\⏮️|previous_track_button|last track button|botao de faixa anterior anterior cena anterior faixa anterior flechas para esquerda seta
    \\🔼|arrow_up_small|upwards button|botao apontando para cima acima botao botao de triangulo apontando para cima para cima seta
    \\⏫|arrow_double_up|fast up button|botao de avanco para cima dupla flechas para cima para cima seta seta dupla para cima
    \\🔽|arrow_down_small|downwards button|botao apontando para baixo botao botao de triangulo apontando para baixo para baixo seta triangulo
    \\⏬|arrow_double_down|fast down button|botao de avanco para baixo flechas flechas para baixo para baixo retroceder rapido seta
    \\⏸️|pause_button|pause button|botao pausar barra dupla pausado pausar pause
    \\⏹️|stop_button|stop button|botao parar parar quadrado stop
    \\⏺️|record_button|record button|botao gravar botao circulo gravar
    \\⏏️|eject_button|eject button|botao ejetar ejetar
    \\🎦|cinema|film movie cinema|cinema entretenimento filme simbolo do cinema
    \\🔅|low_brightness|dim button|botao de diminuir brilho brilho diminuir escurecer simbolo para reduzir brilho
    \\🔆|high_brightness|bright button|botao de aumentar brilho aumentar brilho brilho simbolo para aumentar brilho
    \\📶|signal_strength|wifi antenna bars|barras de sinal antena antena com barras celular conexao forca do sinal
    \\🛜|wireless|wifi wireless|sem fio banda larga computador conectividade internet ponto de acesso rede
    \\📳|vibration_mode|vibration mode|modo vibratorio cel celular modo smartphone telefone
    \\📴|mobile_phone_off|mute off mobile phone off|telefone celular desligado celular desligado desligue o celular smartphone telefone
    \\♀️|female_sign|female sign|simbolo de feminino feminino mulher
    \\♂️|male_sign|male sign|simbolo de masculino homem masculino
    \\⚧️|transgender_symbol|transgender symbol|simbolo transgenero transgenero
    \\✖️|heavy_multiplication_x|multiply|sinal de multiplicacao × cancelar multiplicacao multiplicar x
    \\➕|heavy_plus_sign|plus|simbolo de adicao + cruz mais matematica sinal
    \\➖|heavy_minus_sign|minus|simbolo de subtracao - − diminuir matematica menos
    \\➗|heavy_division_sign|divide|simbolo de divisao ÷ dividir divisao matematica sinal
    \\🟰|heavy_equals_sign|heavy equals sign|sinal de igual conta iguais igual igualdade matematica resposta
    \\♾️|infinity|infinity|infinito eternidade ilimitado universal
    \\‼️|bangbang|double exclamation mark|dupla exclamacao ! !! exclamacao exclamacao dupla explosao
    \\⁉️|interrobang|exclamation question mark|exclamacao com interrogacao ! !? ? exclamacao interrogacao
    \\❓|question|confused red question mark|ponto de interrogacao vermelho ? interrogacao pergunta ponto ponto de interrogacao
    \\❔|grey_question|white question mark|ponto de interrogacao branco ? delineado interrogacao pergunta pontuacao
    \\❕|grey_exclamation|white exclamation mark|ponto de exclamacao branco ! delineado exclamacao mark ponto
    \\❗|exclamation|heavy_exclamation_mark bang red exclamation mark|ponto de exclamacao vermelho ! exclamacao ponto de exclamacao pontuacao
    \\〰️|wavy_dash|wavy dash|travessao ondulado onda ondulado pontuacao travessao
    \\💱|currency_exchange|currency exchange|cambio de moeda banco cambio dinheiro moeda
    \\💲|heavy_dollar_sign|heavy dollar sign|cifrao dinheiro dolar grana moeda simbolo do dolar
    \\⚕️|medical_symbol|medical symbol|simbolo da medicina bastao de asclepio esculapio medicina simbolo
    \\♻️|recycle|environment green recycling symbol|simbolo de reciclagem reciclagem reclicar simbolo de reciclagem solido universal sinal
    \\⚜️|fleur_de_lis|fleur-de-lis|flor-de-lis cavaleiros simbolo
    \\🔱|trident|trident emblem|emblema de tridente ancora emblema ferramenta navio simbolo de tridente
    \\📛|name_badge|name badge|cracha identificacao nome
    \\🔰|beginner|japanese symbol for beginner|simbolo japones de principiante folha verde e amarela iniciante japones simbolo japones para iniciante verde e amarela
    \\⭕|o|hollow red circle|circulo grande oco aro circulo circulo vermelho vazio grande o
    \\✅|white_check_mark|check mark button|marca de selecao branca ✓ botao check completo feito marca
    \\☑️|ballot_box_with_check|check box with check|caixa de selecao marcada com tique ✓ caixa check feito marca de verificacao
    \\✔️|heavy_check_mark|check mark|marca de selecao ✓ check feito marca marca de verificacao simples
    \\❌|x|cross mark|xis × cancelar multiplicacao multiplicar vermelho x
    \\❎|negative_squared_cross_mark|cross mark button|botao de xis × botao com x botao de caixa com x marcado multiplicar
    \\➰|curly_loop|curly loop|laco encaracolado loop onda ondulado volta
    \\➿|loop|double curly loop|loop encaracolado duas vezes duas vezes duplo encaradolado loop onda
    \\〽️|part_alternation_mark|part alternation mark|sinal japones indicando inicio de musica canto japones simbolo japones de canto
    \\✳️|eight_spoked_asterisk|eight-spoked asterisk|asterisco de oito pontas * asterisco estrela
    \\✴️|eight_pointed_black_star|eight-pointed star|estrela de oito pontas * estrela oito pontas
    \\❇️|sparkle|sparkle|faisca * cruz
    \\©️|copyright|copyright|simbolo de copyright copyright direitos autorais
    \\®️|registered|registered|simbolo de registrado marca registrada marca registrada “r”
    \\™️|tm|trademark trade mark|simbolo de marca registrada marca registrada marca registrada “tm” simbolo
    \\🫟|splatter|splatter|respingo mancha pingo tinta
    \\#️⃣|hash|number keycap: #|
    \\*️⃣|asterisk|keycap: *|
    \\0️⃣|zero|keycap: 0|tecla: 0 0 tecla zero
    \\1️⃣|one|keycap: 1|tecla: 1 1 tecla um
    \\2️⃣|two|keycap: 2|tecla: 2 2 dois tecla
    \\3️⃣|three|keycap: 3|tecla: 3 3 tecla tres
    \\4️⃣|four|keycap: 4|tecla: 4 4 quatro tecla
    \\5️⃣|five|keycap: 5|tecla: 5 5 cinco tecla
    \\6️⃣|six|keycap: 6|tecla: 6 6 seis tecla
    \\7️⃣|seven|keycap: 7|tecla: 7 7 sete tecla
    \\8️⃣|eight|keycap: 8|tecla: 8 8 oito tecla
    \\9️⃣|nine|keycap: 9|tecla: 9 9 nove tecla
    \\🔟|keycap_ten|keycap: 10|
    \\🔠|capital_abcd|letters input latin uppercase|letras latinas maiusculas abcd caracteres latinos maiusculos digitacao inserir caracteres latinos maiusculos latinas letras
    \\🔡|abcd|input latin lowercase|letras latinas minusculas abcd caracteres latinos minusculos digitacao latinas latino letras
    \\🔢|1234|numbers input numbers|numeros 1234 digitacao inserir numeros
    \\🔣|symbols|input symbols|simbolos 〒♪&% digitacao inserir simbolos
    \\🔤|abc|alphabet input latin letters|letras latinas abc alfabeto digitacao ingles inserir alfabeto latino
    \\🅰️|a|a button (blood type)|botao a (tipo sanguineo) a sangue tipo a tipo sanguineo tipo sanguineo a
    \\🆎|ab|ab button (blood type)|botao ab (tipo sanguineo) ab sangue tipo ab tipo sanguineo tipo sanguineo ab
    \\🅱️|b|b button (blood type)|botao b (tipo sanguineo) b sangue tipo b tipo sanguineo tipo sanguineo b
    \\🆑|cl|cl button|botao cl cl limpar simbolo do cl
    \\🆒|cool|cool button|botao "cool" botao cool cool legal simbolo “cool”
    \\🆓|free|free button|botao "free" free gratis gratuito simbolo simbolo “free”
    \\ℹ️|information_source|information|informacoes i informacao simbolo simbolo de informacoes
    \\🆔|id|id button|botao id id identidade simbolo simbolo “id”
    \\Ⓜ️|m|circled m|circulo com a letra m circulo letra m m
    \\🆕|new|fresh new button|botao "new" new novo simbolo
    \\🆖|ng|ng button|botao ng ng simbolo simbolo “ng”
    \\🅾️|o2|o button (blood type)|botao o (tipo sanguineo) o sangue tipo o tipo sanguineo tipo sanguineo o
    \\🆗|ok|yes ok button|botao ok ok sim simbolo “ok”
    \\🅿️|parking|p button|botao p estacionamento estacionar garagem de carros
    \\🆘|sos|help emergency sos button|botao sos ajuda simbolo simbolo “sos” socorro sos
    \\🆙|up|up! button|botao "up!" para cima simbolo simbolo “up!” up up!
    \\🆚|vs|vs button|botao vs simbolo simbolo “vs” versus vs
    \\🈁|koko|japanese “here” button|botao japones de “aqui” aqui botao japones katakana
    \\🈂️|sa|japanese “service charge” button|botao japones de “taxa de servico” botao cobranca japones katakana servico
    \\🈷️|u6708|japanese “monthly amount” button|botao japones de “quantidade mensal” botao ideograma japones mensal quantidade valor
    \\🈶|u6709|japanese “not free of charge” button|botao japones de “nao gratuito” botao gratis ideograma isento japones nao
    \\🈯|u6307|japanese “reserved” button|botao japones de “reservado” botao ideograma japones reservado
    \\🉐|ideograph_advantage|japanese “bargain” button|botao japones de “barganha” barganha botao ideograma japones promocao
    \\🈹|u5272|japanese “discount” button|botao japones de “desconto” botao desconto ideograma japones
    \\🈚|u7121|japanese “free of charge” button|botao japones de “gratuito” botao gratuito ideograma japones
    \\🈲|u7981|japanese “prohibited” button|botao japones de “proibido” botao ideograma japones proibido
    \\🉑|accept|japanese “acceptable” button|botao japones de “aceitavel” aceitavel botao ideograma japones
    \\🈸|u7533|japanese “application” button|botao japones de “aplicacao” aplicacao aplicativo botao ideograma japones
    \\🈴|u5408|japanese “passing grade” button|botao japones de “nota minima” botao ideograma japones minima nota
    \\🈳|u7a7a|japanese “vacancy” button|botao japones de “vago” botao ideograma japones vago
    \\㊗️|congratulations|japanese “congratulations” button|botao japones de “parabens” botao ideograma japones parabens
    \\㊙️|secret|japanese “secret” button|botao japones de “segredo” botao ideograma japones segredo
    \\🈺|u55b6|japanese “open for business” button|botao japones de “aberto para negocios” aberto botao ideograma japones negocios
    \\🈵|u6e80|japanese “no vacancy” button|botao japones de “sem vagas” botao ideograma japones sem vagas
    \\🔴|red_circle|red circle|circulo vermelho bola vermelha circulo circulo vermelho grande geometrico vermelho
    \\🟠|orange_circle|orange circle|circulo laranja circulo laranja
    \\🟡|yellow_circle|yellow circle|circulo amarelo amarelo circulo
    \\🟢|green_circle|green circle|circulo verde circulo verde
    \\🔵|large_blue_circle|blue circle|circulo azul azul bolinha azul circulo circulo azul grande geometrico
    \\🟣|purple_circle|purple circle|circulo roxo circulo roxo
    \\🟤|brown_circle|brown circle|circulo marrom circulo marrom
    \\⚫|black_circle|black circle|circulo preto circulo geometrico preto
    \\⚪|white_circle|white circle|circulo branco branco circulo geometrico
    \\🟥|red_square|red square|quadrado vermelho quadrado vermelho
    \\🟧|orange_square|orange square|quadrado laranja laranja quadrado
    \\🟨|yellow_square|yellow square|quadrado amarelo amarelo quadrado
    \\🟩|green_square|green square|quadrado verde quadrado verde
    \\🟦|blue_square|blue square|quadrado azul anil azul quadrado
    \\🟪|purple_square|purple square|quadrado roxo purpura quadrado roxo
    \\🟫|brown_square|brown square|quadrado marrom marrom quadrado
    \\⬛|black_large_square|black large square|quadrado preto grande geometrico preto quadrado
    \\⬜|white_large_square|white large square|quadrado branco grande geometrico quadrado
    \\◼️|black_medium_square|black medium square|quadrado preto medio geometrico quadrado
    \\◻️|white_medium_square|white medium square|quadrado branco medio geometrico quadrado
    \\◾|black_medium_small_square|black medium-small square|quadrado preto medio menor geometrico preto quadrado
    \\◽|white_medium_small_square|white medium-small square|quadrado branco medio menor branco geometrico quadrado
    \\▪️|black_small_square|black small square|quadrado preto pequeno geometrico pequeno preto quadrado
    \\▫️|white_small_square|white small square|quadrado branco pequeno branco geometrico pequeno quadrado
    \\🔶|large_orange_diamond|large orange diamond|losango laranja grande cor de laranja diamante diamante cor de laranja grande diamante laranja grande geometrico laranja
    \\🔷|large_blue_diamond|large blue diamond|losango azul grande azul balao diamante diamante azul grande geometrico losango
    \\🔸|small_orange_diamond|small orange diamond|losango laranja pequeno cor de laranja diamante diamante cor de laranja pequeno diamante laranja pequeno geometrico laranja
    \\🔹|small_blue_diamond|small blue diamond|losango azul pequeno azul diamante diamante azul pequeno geometrico losango
    \\🔺|small_red_triangle|red triangle pointed up|triangulo vermelho para cima geometrico triangulo triangulo vermelho apontando para cima vermelho
    \\🔻|small_red_triangle_down|red triangle pointed down|triangulo vermelho para baixo geometrico triangulo triangulo vermelho apontando para baixo vermelho
    \\💠|diamond_shape_with_a_dot_inside|diamond with a dot|diamante com um ponto comico dentro diamante diamante com ponto formato de diamante
    \\🔘|radio_button|radio button|botao de opcao botao geometrico radio
    \\🔳|white_square_button|white square button|botao quadrado branco botao botao quadrado branco e preto quadrado
    \\🔲|black_square_button|black square button|botao quadrado preto botao botao quadrado preto e branco geometrico quadrado
    \\🏁|checkered_flag|milestone finish chequered flag|bandeira quadriculada bandeira chegada corrida esporte quadriculada vitoria
    \\🚩|triangular_flag_on_post|triangular flag|bandeira triangular bandeira informacoes localizacao poste triangular vermelha
    \\🎌|crossed_flags|crossed flags|bandeiras cruzadas bandeira comemoracao cruzadas cruzar japao japones
    \\🏴|black_flag|black flag|bandeira preta bandeira preta tremulando
    \\🏳️|white_flag|white flag|bandeira branca bandeira branca paz tremulando
    \\🏳️‍🌈|rainbow_flag|pride rainbow flag|bandeira do arco-iris arco-iris bandeira bissexual gay lesbica lgbt
    \\🏳️‍⚧️|transgender_flag|transgender flag|bandeira transgenero azul claro bandeira branco rosa transgenero
    \\🏴‍☠️|pirate_flag|pirate flag|bandeira de pirata bandeira caveira osso pirata saque tesouro
    \\🇦🇨|ascension_island|flag: ascension island|
    \\🇦🇩|andorra|flag: andorra|
    \\🇦🇪|united_arab_emirates|flag: united arab emirates|
    \\🇦🇫|afghanistan|flag: afghanistan|
    \\🇦🇬|antigua_barbuda|flag: antigua & barbuda|
    \\🇦🇮|anguilla|flag: anguilla|
    \\🇦🇱|albania|flag: albania|
    \\🇦🇲|armenia|flag: armenia|
    \\🇦🇴|angola|flag: angola|
    \\🇦🇶|antarctica|flag: antarctica|
    \\🇦🇷|argentina|flag: argentina|
    \\🇦🇸|american_samoa|flag: american samoa|
    \\🇦🇹|austria|flag: austria|
    \\🇦🇺|australia|flag: australia|
    \\🇦🇼|aruba|flag: aruba|
    \\🇦🇽|aland_islands|flag: aland islands|
    \\🇦🇿|azerbaijan|flag: azerbaijan|
    \\🇧🇦|bosnia_herzegovina|flag: bosnia & herzegovina|
    \\🇧🇧|barbados|flag: barbados|
    \\🇧🇩|bangladesh|flag: bangladesh|
    \\🇧🇪|belgium|flag: belgium|
    \\🇧🇫|burkina_faso|flag: burkina faso|
    \\🇧🇬|bulgaria|flag: bulgaria|
    \\🇧🇭|bahrain|flag: bahrain|
    \\🇧🇮|burundi|flag: burundi|
    \\🇧🇯|benin|flag: benin|
    \\🇧🇱|st_barthelemy|flag: st. barthelemy|
    \\🇧🇲|bermuda|flag: bermuda|
    \\🇧🇳|brunei|flag: brunei|
    \\🇧🇴|bolivia|flag: bolivia|
    \\🇧🇶|caribbean_netherlands|flag: caribbean netherlands|
    \\🇧🇷|brazil|flag: brazil|
    \\🇧🇸|bahamas|flag: bahamas|
    \\🇧🇹|bhutan|flag: bhutan|
    \\🇧🇻|bouvet_island|flag: bouvet island|
    \\🇧🇼|botswana|flag: botswana|
    \\🇧🇾|belarus|flag: belarus|
    \\🇧🇿|belize|flag: belize|
    \\🇨🇦|canada|flag: canada|
    \\🇨🇨|cocos_islands|keeling flag: cocos (keeling) islands|
    \\🇨🇩|congo_kinshasa|flag: congo - kinshasa|
    \\🇨🇫|central_african_republic|flag: central african republic|
    \\🇨🇬|congo_brazzaville|flag: congo - brazzaville|
    \\🇨🇭|switzerland|flag: switzerland|
    \\🇨🇮|cote_divoire|ivory flag: cote d’ivoire|
    \\🇨🇰|cook_islands|flag: cook islands|
    \\🇨🇱|chile|flag: chile|
    \\🇨🇲|cameroon|flag: cameroon|
    \\🇨🇳|cn|china flag: china|
    \\🇨🇴|colombia|flag: colombia|
    \\🇨🇵|clipperton_island|flag: clipperton island|
    \\🇨🇶|flag_sark|flag: sark|
    \\🇨🇷|costa_rica|flag: costa rica|
    \\🇨🇺|cuba|flag: cuba|
    \\🇨🇻|cape_verde|flag: cape verde|
    \\🇨🇼|curacao|flag: curacao|
    \\🇨🇽|christmas_island|flag: christmas island|
    \\🇨🇾|cyprus|flag: cyprus|
    \\🇨🇿|czech_republic|flag: czechia|
    \\🇩🇪|de|flag germany flag: germany|
    \\🇩🇬|diego_garcia|flag: diego garcia|
    \\🇩🇯|djibouti|flag: djibouti|
    \\🇩🇰|denmark|flag: denmark|
    \\🇩🇲|dominica|flag: dominica|
    \\🇩🇴|dominican_republic|flag: dominican republic|
    \\🇩🇿|algeria|flag: algeria|
    \\🇪🇦|ceuta_melilla|flag: ceuta & melilla|
    \\🇪🇨|ecuador|flag: ecuador|
    \\🇪🇪|estonia|flag: estonia|
    \\🇪🇬|egypt|flag: egypt|
    \\🇪🇭|western_sahara|flag: western sahara|
    \\🇪🇷|eritrea|flag: eritrea|
    \\🇪🇸|es|spain flag: spain|
    \\🇪🇹|ethiopia|flag: ethiopia|
    \\🇪🇺|eu|european_union flag: european union|
    \\🇫🇮|finland|flag: finland|
    \\🇫🇯|fiji|flag: fiji|
    \\🇫🇰|falkland_islands|flag: falkland islands|
    \\🇫🇲|micronesia|flag: micronesia|
    \\🇫🇴|faroe_islands|flag: faroe islands|
    \\🇫🇷|fr|france french flag: france|
    \\🇬🇦|gabon|flag: gabon|
    \\🇬🇧|gb|uk flag british flag: united kingdom|
    \\🇬🇩|grenada|flag: grenada|
    \\🇬🇪|georgia|flag: georgia|
    \\🇬🇫|french_guiana|flag: french guiana|
    \\🇬🇬|guernsey|flag: guernsey|
    \\🇬🇭|ghana|flag: ghana|
    \\🇬🇮|gibraltar|flag: gibraltar|
    \\🇬🇱|greenland|flag: greenland|
    \\🇬🇲|gambia|flag: gambia|
    \\🇬🇳|guinea|flag: guinea|
    \\🇬🇵|guadeloupe|flag: guadeloupe|
    \\🇬🇶|equatorial_guinea|flag: equatorial guinea|
    \\🇬🇷|greece|flag: greece|
    \\🇬🇸|south_georgia_south_sandwich_islands|flag: south georgia & south sandwich islands|
    \\🇬🇹|guatemala|flag: guatemala|
    \\🇬🇺|guam|flag: guam|
    \\🇬🇼|guinea_bissau|flag: guinea-bissau|
    \\🇬🇾|guyana|flag: guyana|
    \\🇭🇰|hong_kong|flag: hong kong sar china|
    \\🇭🇲|heard_mcdonald_islands|flag: heard island & mcdonald islands|
    \\🇭🇳|honduras|flag: honduras|
    \\🇭🇷|croatia|flag: croatia|
    \\🇭🇹|haiti|flag: haiti|
    \\🇭🇺|hungary|flag: hungary|
    \\🇮🇨|canary_islands|flag: canary islands|
    \\🇮🇩|indonesia|flag: indonesia|
    \\🇮🇪|ireland|flag: ireland|
    \\🇮🇱|israel|flag: israel|
    \\🇮🇲|isle_of_man|flag: isle of man|
    \\🇮🇳|india|flag: india|
    \\🇮🇴|british_indian_ocean_territory|flag: british indian ocean territory|
    \\🇮🇶|iraq|flag: iraq|
    \\🇮🇷|iran|flag: iran|
    \\🇮🇸|iceland|flag: iceland|
    \\🇮🇹|it|italy flag: italy|
    \\🇯🇪|jersey|flag: jersey|
    \\🇯🇲|jamaica|flag: jamaica|
    \\🇯🇴|jordan|flag: jordan|
    \\🇯🇵|jp|japan flag: japan|
    \\🇰🇪|kenya|flag: kenya|
    \\🇰🇬|kyrgyzstan|flag: kyrgyzstan|
    \\🇰🇭|cambodia|flag: cambodia|
    \\🇰🇮|kiribati|flag: kiribati|
    \\🇰🇲|comoros|flag: comoros|
    \\🇰🇳|st_kitts_nevis|flag: st. kitts & nevis|
    \\🇰🇵|north_korea|flag: north korea|
    \\🇰🇷|kr|korea flag: south korea|
    \\🇰🇼|kuwait|flag: kuwait|
    \\🇰🇾|cayman_islands|flag: cayman islands|
    \\🇰🇿|kazakhstan|flag: kazakhstan|
    \\🇱🇦|laos|flag: laos|
    \\🇱🇧|lebanon|flag: lebanon|
    \\🇱🇨|st_lucia|flag: st. lucia|
    \\🇱🇮|liechtenstein|flag: liechtenstein|
    \\🇱🇰|sri_lanka|flag: sri lanka|
    \\🇱🇷|liberia|flag: liberia|
    \\🇱🇸|lesotho|flag: lesotho|
    \\🇱🇹|lithuania|flag: lithuania|
    \\🇱🇺|luxembourg|flag: luxembourg|
    \\🇱🇻|latvia|flag: latvia|
    \\🇱🇾|libya|flag: libya|
    \\🇲🇦|morocco|flag: morocco|
    \\🇲🇨|monaco|flag: monaco|
    \\🇲🇩|moldova|flag: moldova|
    \\🇲🇪|montenegro|flag: montenegro|
    \\🇲🇫|st_martin|flag: st. martin|
    \\🇲🇬|madagascar|flag: madagascar|
    \\🇲🇭|marshall_islands|flag: marshall islands|
    \\🇲🇰|macedonia|flag: north macedonia|
    \\🇲🇱|mali|flag: mali|
    \\🇲🇲|myanmar|burma flag: myanmar (burma)|
    \\🇲🇳|mongolia|flag: mongolia|
    \\🇲🇴|macau|flag: macao sar china|
    \\🇲🇵|northern_mariana_islands|flag: northern mariana islands|
    \\🇲🇶|martinique|flag: martinique|
    \\🇲🇷|mauritania|flag: mauritania|
    \\🇲🇸|montserrat|flag: montserrat|
    \\🇲🇹|malta|flag: malta|
    \\🇲🇺|mauritius|flag: mauritius|
    \\🇲🇻|maldives|flag: maldives|
    \\🇲🇼|malawi|flag: malawi|
    \\🇲🇽|mexico|flag: mexico|
    \\🇲🇾|malaysia|flag: malaysia|
    \\🇲🇿|mozambique|flag: mozambique|
    \\🇳🇦|namibia|flag: namibia|
    \\🇳🇨|new_caledonia|flag: new caledonia|
    \\🇳🇪|niger|flag: niger|
    \\🇳🇫|norfolk_island|flag: norfolk island|
    \\🇳🇬|nigeria|flag: nigeria|
    \\🇳🇮|nicaragua|flag: nicaragua|
    \\🇳🇱|netherlands|flag: netherlands|
    \\🇳🇴|norway|flag: norway|
    \\🇳🇵|nepal|flag: nepal|
    \\🇳🇷|nauru|flag: nauru|
    \\🇳🇺|niue|flag: niue|
    \\🇳🇿|new_zealand|flag: new zealand|
    \\🇴🇲|oman|flag: oman|
    \\🇵🇦|panama|flag: panama|
    \\🇵🇪|peru|flag: peru|
    \\🇵🇫|french_polynesia|flag: french polynesia|
    \\🇵🇬|papua_new_guinea|flag: papua new guinea|
    \\🇵🇭|philippines|flag: philippines|
    \\🇵🇰|pakistan|flag: pakistan|
    \\🇵🇱|poland|flag: poland|
    \\🇵🇲|st_pierre_miquelon|flag: st. pierre & miquelon|
    \\🇵🇳|pitcairn_islands|flag: pitcairn islands|
    \\🇵🇷|puerto_rico|flag: puerto rico|
    \\🇵🇸|palestinian_territories|flag: palestinian territories|
    \\🇵🇹|portugal|flag: portugal|
    \\🇵🇼|palau|flag: palau|
    \\🇵🇾|paraguay|flag: paraguay|
    \\🇶🇦|qatar|flag: qatar|
    \\🇷🇪|reunion|flag: reunion|
    \\🇷🇴|romania|flag: romania|
    \\🇷🇸|serbia|flag: serbia|
    \\🇷🇺|ru|russia flag: russia|
    \\🇷🇼|rwanda|flag: rwanda|
    \\🇸🇦|saudi_arabia|flag: saudi arabia|
    \\🇸🇧|solomon_islands|flag: solomon islands|
    \\🇸🇨|seychelles|flag: seychelles|
    \\🇸🇩|sudan|flag: sudan|
    \\🇸🇪|sweden|flag: sweden|
    \\🇸🇬|singapore|flag: singapore|
    \\🇸🇭|st_helena|flag: st. helena, ascension & tristan da cunha|
    \\🇸🇮|slovenia|flag: slovenia|
    \\🇸🇯|svalbard_jan_mayen|flag: svalbard & jan mayen|
    \\🇸🇰|slovakia|flag: slovakia|
    \\🇸🇱|sierra_leone|flag: sierra leone|
    \\🇸🇲|san_marino|flag: san marino|
    \\🇸🇳|senegal|flag: senegal|
    \\🇸🇴|somalia|flag: somalia|
    \\🇸🇷|suriname|flag: suriname|
    \\🇸🇸|south_sudan|flag: south sudan|
    \\🇸🇹|sao_tome_principe|flag: sao tome & principe|
    \\🇸🇻|el_salvador|flag: el salvador|
    \\🇸🇽|sint_maarten|flag: sint maarten|
    \\🇸🇾|syria|flag: syria|
    \\🇸🇿|swaziland|flag: eswatini|
    \\🇹🇦|tristan_da_cunha|flag: tristan da cunha|
    \\🇹🇨|turks_caicos_islands|flag: turks & caicos islands|
    \\🇹🇩|chad|flag: chad|
    \\🇹🇫|french_southern_territories|flag: french southern and antarctic lands|
    \\🇹🇬|togo|flag: togo|
    \\🇹🇭|thailand|flag: thailand|
    \\🇹🇯|tajikistan|flag: tajikistan|
    \\🇹🇰|tokelau|flag: tokelau|
    \\🇹🇱|timor_leste|flag: timor-leste|
    \\🇹🇲|turkmenistan|flag: turkmenistan|
    \\🇹🇳|tunisia|flag: tunisia|
    \\🇹🇴|tonga|flag: tonga|
    \\🇹🇷|tr|turkey flag: turkiye|
    \\🇹🇹|trinidad_tobago|flag: trinidad & tobago|
    \\🇹🇻|tuvalu|flag: tuvalu|
    \\🇹🇼|taiwan|flag: taiwan|
    \\🇹🇿|tanzania|flag: tanzania|
    \\🇺🇦|ukraine|flag: ukraine|
    \\🇺🇬|uganda|flag: uganda|
    \\🇺🇲|us_outlying_islands|flag: u.s. outlying islands|
    \\🇺🇳|united_nations|flag: united nations|
    \\🇺🇸|us|flag united america flag: united states|
    \\🇺🇾|uruguay|flag: uruguay|
    \\🇺🇿|uzbekistan|flag: uzbekistan|
    \\🇻🇦|vatican_city|flag: vatican city|
    \\🇻🇨|st_vincent_grenadines|flag: st. vincent & grenadines|
    \\🇻🇪|venezuela|flag: venezuela|
    \\🇻🇬|british_virgin_islands|flag: british virgin islands|
    \\🇻🇮|us_virgin_islands|flag: u.s. virgin islands|
    \\🇻🇳|vietnam|flag: vietnam|
    \\🇻🇺|vanuatu|flag: vanuatu|
    \\🇼🇫|wallis_futuna|flag: wallis & futuna|
    \\🇼🇸|samoa|flag: samoa|
    \\🇽🇰|kosovo|flag: kosovo|
    \\🇾🇪|yemen|flag: yemen|
    \\🇾🇹|mayotte|flag: mayotte|
    \\🇿🇦|south_africa|flag: south africa|
    \\🇿🇲|zambia|flag: zambia|
    \\🇿🇼|zimbabwe|flag: zimbabwe|
    \\🏴󠁧󠁢󠁥󠁮󠁧󠁿|england|flag: england|
    \\🏴󠁧󠁢󠁳󠁣󠁴󠁿|scotland|flag: scotland|
    \\🏴󠁧󠁢󠁷󠁬󠁳󠁿|wales|flag: wales|
;

pub const Entry = struct {
    glyph: []const u8,
    /// O nome de digitar (`:nome:`).
    code: []const u8,
    en: []const u8,
    pt: []const u8,
};

pub fn get(i: usize) Entry {
    const line = blob[offsets[i] .. offsets[i + 1] - 1];
    var it = std.mem.splitScalar(u8, line, '|');
    const glyph = it.next() orelse "";
    const code = it.next() orelse "";
    const en = it.next() orelse "";
    const pt = it.next() orelse "";
    return .{ .glyph = glyph, .code = code, .en = en, .pt = pt };
}

/// Só o emoji da linha i (o desenho da grade não precisa do resto).
pub fn glyphOf(i: usize) []const u8 {
    const line = blob[offsets[i]..offsets[i + 1]];
    return line[0 .. std.mem.indexOfScalar(u8, line, '|') orelse 0];
}

/// Categoria em que está o emoji i.
pub fn categoryOf(i: usize) usize {
    for (categories, 0..) |cat, k| {
        if (i < @as(usize, cat.first) + cat.count) return k;
    }
    return categories.len - 1;
}

/// O emoji com este nome exato (`:joy:` digitado à mão). Varre a tabela: é
/// só na hora de enviar.
pub fn byCode(code: []const u8) ?u16 {
    if (code.len == 0) return null;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const line = blob[offsets[i]..offsets[i + 1]];
        const bar = std.mem.indexOfScalar(u8, line, '|') orelse continue;
        const rest = line[bar + 1..];
        if (rest.len > code.len and rest[code.len] == '|' and std.mem.eql(u8, rest[0..code.len], code)) return i;
    }
    return null;
}

/// Minúsculas e sem acento, como as palavras da tabela. `buf` tem que caber
/// `q` (o resultado nunca é maior).
pub fn fold(buf: []u8, q: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < q.len and n < buf.len) {
        const ch = q[i];
        if (ch == 0xC3 and i + 1 < q.len) {
            const up = q[i + 1] | 0x20;
            buf[n] = switch (up) {
                0xA0...0xA5 => 'a',
                0xA7 => 'c',
                0xA8...0xAB => 'e',
                0xAC...0xAF => 'i',
                0xB1 => 'n',
                0xB2...0xB6 => 'o',
                0xB9...0xBC => 'u',
                else => '?',
            };
            n += 1;
            i += 2;
            continue;
        }
        buf[n] = std.ascii.toLower(ch);
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

fn wordStart(hay: []const u8, at: usize) bool {
    return at == 0 or !std.ascii.isAlphanumeric(hay[at - 1]);
}

/// Quanto o texto casa com a busca (já com `fold`): 0 = não casa.
/// Vale para o nome de um emoji personalizado também.
pub fn matchName(name: []const u8, q: []const u8) i32 {
    if (name.len < q.len) return 0;
    if (std.ascii.eqlIgnoreCase(name, q)) return 1000;
    if (std.ascii.startsWithIgnoreCase(name, q)) return 800 - @as(i32, @intCast(@min(name.len, 60)));
    const at = std.ascii.findIgnoreCase(name, q) orelse return 0;
    return (if (wordStart(name, at)) @as(i32, 500) else 300) - @as(i32, @intCast(@min(name.len, 60)));
}

fn score(e: Entry, q: []const u8) i32 {
    const s = matchName(e.code, q);
    if (s != 0) return s;
    // Palavras: as duas línguas valem o mesmo; começo de palavra vale mais.
    var best: i32 = 0;
    for ([_][]const u8{ e.en, e.pt }) |hay| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, hay, from, q)) |at| {
            if (wordStart(hay, at)) {
                best = @max(best, 200);
                break;
            }
            best = @max(best, 60);
            from = at + 1;
        }
    }
    return best;
}

pub const Hit = struct { index: u16, score: i32 };

/// Os melhores resultados para `query`, do melhor para o pior. Roda só quando
/// o texto da busca muda.
pub fn search(query: []const u8, out: []Hit) []Hit {
    var qb: [64]u8 = undefined;
    const q = fold(&qb, query);
    if (q.len == 0 or out.len == 0) return out[0..0];
    var n: usize = 0;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const sc = score(get(i), q);
        if (sc == 0) continue;
        // Inserção ordenada: empate fica na ordem do Unicode.
        var k = n;
        if (n == out.len) {
            if (sc <= out[n - 1].score) continue;
            k = n - 1;
        } else n += 1;
        while (k > 0 and out[k - 1].score < sc) : (k -= 1) out[k] = out[k - 1];
        out[k] = .{ .index = i, .score = sc };
    }
    return out[0..n];
}

test "tabela de emoji" {
    try std.testing.expectEqual(@as(usize, count + 1), offsets.len);
    try std.testing.expectEqualStrings("😀", glyphOf(0));
    const joy = byCode("joy").?;
    try std.testing.expectEqualStrings("😂", get(joy).glyph);
    try std.testing.expect(byCode("nao_existe_isso") == null);
    var hits: [16]Hit = undefined;
    const r = search("joy", &hits);
    try std.testing.expect(r.len > 0);
    try std.testing.expectEqualStrings("😂", get(r[0].index).glyph);
    // Em português, com ou sem acento.
    const r2 = search("coração", &hits);
    try std.testing.expect(r2.len > 0);
    try std.testing.expect(search("zzzqqq", &hits).len == 0);
    try std.testing.expect(categoryOf(0) == 0);
    // Tudo tem nome e nenhum nome se repete à toa.
    for (0..count) |i| try std.testing.expect(get(i).code.len > 0);
}
